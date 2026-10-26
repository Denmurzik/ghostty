# M2 — Tabs, splits, multiple windows, custom titlebar: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ghostty.exe` on Windows 11 hosts many top-level windows, each with a custom DWM titlebar (Mica, own caption buttons, snap layouts) that doubles as a Direct2D/DirectWrite tab strip; every tab holds a core `SplitTree` of terminal surfaces; a second launch opens a window in the running instance over a named pipe; every apprt action is implemented or explicitly deferred; with the last window closed Ghostty keeps running in the notification area, and closing a tab ends only that tab's shell and its console clients, and tabs can be dragged out into new windows or onto other windows with their processes intact (owner decisions 2026-10-26); files dropped from Explorer insert shell-quoted paths, and typing and TUI scrolling feel immediate (per-scenario keypress/wheel/output→present thresholds in Task 36, e.g. key echo p95 ≤ 16 ms ReleaseFast, ≤ 50 ms Debug; owner requirements 2026-10-26).

**Revision 2 (architect-m2b, 2026-10-26):** applies `docs/windows/plans/M2-preflight-review.md` (dispositions at the end), splits Task 6 into 6a/6b, and adds Task 36 (latency measurement — the first task of M2, in W1, after the owner reported lag in ReleaseFast too and high lag when scrolling TUIs), Task 37 (latency fixes inside Ghostty), Task 40 (ConPTY latency mitigation), Task 38 (file drop), Task 39 (device loss with a resident process). Task numbers of revision 1 are kept so review references stay valid; the wave table is the execution order.

**Architecture:** `App` → `Window` (top-level HWND, custom frame, strip painted with D2D into the extended-frame client area) → `Tab` (one container child HWND per tab, holds `SplitTree(Surface)`) → `Surface` (child HWND + flip-model swap chain, unchanged from M1). Window procedures dispatch to small feature modules (`frame`, `strip_input`, `theme`, `taskbar`, `Chrome`) through hooks wired once in Task 6; action handling moves from `App.performAction` to `actions.zig` plus per-area handler files. A per-user/session/class/elevation named pipe, claimed in `App.init` and served by one IPC thread, carries single-instance requests now and the tmux shim in M4. File drops use one OLE `IDropTarget` per top-level window. A std-only latency tracer (`src/os/windows_latency.zig`, off unless `GHOSTTY_LATENCY_TRACE` is set) stamps input, pty write, pty output and present.

**Tech Stack:** Zig 0.17.0, MSVC ABI, Win32 (user32/dwmapi/uxtheme/comctl32/shell32/advapi32/winmm), Direct2D 1.0 + DirectWrite (COM, hand-written in `pkg/win32`), core `src/datastruct/split_tree.zig`, named pipes (overlapped), PowerShell e2e harness.

**Spec:** `docs/windows/SPEC.md` (authority with `docs/windows/DECISIONS.md` incl. "Owner decisions (2026-10-26)"; M2 rulings in SPEC §18 items 5–15). Inputs: `docs/windows/recon/apprt.md` §2 (action table), §3 (GTK structure); M1 plan and ledger `.superpowers/sdd/M1-core-and-window/progress.md` (carry-overs, table at the end).

## Global Constraints

Carried from M1 (every task implicitly includes these):

- Zig 0.17.0 at `C:\tools\zig-x86_64-windows-0.17.0\zig.exe` (always the full path). Shell: Git Bash. Target ABI MSVC (R3). Minimum OS Windows 11 22H2.
- Pure Win32 + DWM apprt in `src/apprt/win32`; no WinUI, no GTK, no .NET (R5). Chrome = Direct2D + DirectWrite; text inputs = native `EDIT` controls (SPEC D7).
- Code stays upstreamable: Windows code in its own dirs; core edits platform-gated and listed. **M2 core touch points (complete list):** `src/config/Config.zig` (new `windows-single-instance` option — Task 20; one doc sentence on the Windows default of `quit-after-last-window-closed`, which M1 already set to `false` via `os == .linux` at `Config.zig:2645` — Task 28); `src/config/command.zig` (`formatEntry` without the 4096-byte fixed buffer — Task 15); `src/Command.zig` + `src/termio/Exec.zig` Windows-only process teardown (Task 29); `src/os/windows_latency.zig` (new, std only) + its export in `src/os/main.zig` + Windows-only marks in `src/termio/Exec.zig` and a diagnostic ConPTY flags/DLL override in `src/pty.zig` + `src/os/windows.zig` (Task 36); Windows-only read-path changes in `src/termio/Exec.zig` (Task 37, if measured); the ConPTY mitigation in `src/pty.zig`/`src/os/windows.zig` (Task 40, if measured; a `windows-conpty` option in `src/config/Config.zig` only with the lead's approval, chain 40→20→28); a Windows-gated optimize override for C dependencies in `src/build/SharedDeps.zig` only if Task 37's measurement selects it.
- Config path, default shell, cache/log locations exactly as M1 (DECISIONS, SPEC §18.4).
- Commits: no `Co-Authored-By` or similar trailers.
- Bindings: hand-written in `pkg/win32` (D6), append-only, W-variants, nullable returns as optionals, `callconv(.winapi)`; COM interfaces list ALL vtable slots with a slot-count test against SDK 10.0.26100 headers. Core (`src/os`, `src/termio`, `src/config`, `src/font`) never imports `win32`.
- Zig 0.17 std: no `std.time.Timer`/`std.Thread.sleep`; use the Io idioms of the touched file (`global.io()`, `std.Io.Timestamp.now(io, .awake)`, `io.sleep`).
- Worktree bootstrap: `cmd //c mklink /J "<worktree>\zig-pkg" "C:\D\den4ik\Ghostty\zig-pkg"` before the first build; a worktree's first (cold) build runs with `run_in_background` under `timeout 1500` through the test-lock.

New or changed for M2:

- **Builds `-j2`** (lead ruling, M1 ledger; `-j1` for a full `zig build` that OOMs). Strictly one build/test at a time through the test-lock. Bash timeout 600000 on every build/test command. Check free RAM before a full-suite run; prefer focused `-Dtest-filter`.
- **Timing acceptance only on ReleaseFast** (`--prefix zig-out-rf`, `$env:GHOSTTY_E2E_EXE`); Debug timings are reference only. Debug latency is recorded against Task 36's target column, not gated (owner decision 2026-10-26: daily use is ReleaseFast).
- **GUI tests only through the runner** `test/windows/e2e.ps1` (or `Invoke-GuiScenario`) holding the shared desktop lock `%TEMP%\gui-e2e.lock`. Never send input, take focus, or capture the screen outside a scenario.
- **Never start `ghostty.exe` outside the harness** (`Start-E2eGhostty`, `measure-ram.ps1`, the spike's `run.ps1`, all of which write `class` through the one Harness config writer of Task 4). A bare `zig-out\bin\ghostty.exe` run shares the Debug pipe with the owner's Debug Ghostty once Task 11 lands, and the owner's next launch would open inside an agent process that the agent later kills.
- **RAM in GUI runs:** a scenario with more than 4 surfaces checks free physical memory ≥ 2.5 GB first and SKIPs otherwise (`Assert-FreeRam 2.5` in `_common.ps1`, Task 4); Debug runs of such scenarios also take the test-lock.
- **Owner safety:** every launched Ghostty runs in the e2e sandbox with its own `class = ghostty-e2e-<hex>` so its pipe can never reach, or be reached by, the owner's Ghostty; scripts kill only processes they started; never change system settings (display scaling, theme, default apps), never broadcast `WM_SETTINGCHANGE`, never write the owner's registry or `%USERPROFILE%\.config`; keyboard layouts and clipboard restored as in M1; screenshots only of Ghostty windows. DPI and colour-scheme changes are simulated through the test-only IPC ops (SPEC §18.8).
- **Every confirmation dialog runs from a posted-message handler**, never inside `performAction`, a core callback or an IPC op handler (dialog loops re-enter the window procedure).
- **UI thread owns** every HWND, the D2D/DWrite objects and the tab/split model; the IPC thread only moves bytes and posts `WM_GHOSTTY_IPC`; it never calls `SendMessage`. OLE drop callbacks (Task 38) only copy data and post `WM_GHOSTTY_DROP`; the core is called from that posted message.
- **Elevation:** an elevated Ghostty never accepts requests from a non-elevated process and vice versa (pipe name marker, mandatory label, client token check — Tasks 5, 8); no request ever carries a command to run (`--command=`/`-e` are never forwarded).
- **Window size math goes through `frame.nonClientSize(window)`** (Tasks 2, 6a, 17): no task calls `AdjustWindowRectExForDpi` for a `GhosttyWindow` directly. `window.dpi` is the single DPI source for a window and everything inside it; only window creation and `WM_DPICHANGED` read the system value (Tasks 6a, 23).
- **RAM:** one D2D factory, one DWrite factory and one DC render target per process (UI thread); no per-window D3D device for chrome unless Task 12's spike rules otherwise.
- Test names start with `win32 ` (apprt + bindings), `d3d11 ` (renderer). Renderer test commands pass `-Dapp-runtime=none`.

Command abbreviations (expand literally; shell state does not persist):
- `LOCK` = `bash "%USERPROFILE%/.claude/mods/teamlead/skills/teamlead/scripts/test-lock" --`
- `ZIG` = `"C:/tools/zig-x86_64-windows-0.17.0/zig.exe"`
- `E2E` = `powershell -NoProfile -ExecutionPolicy Bypass -File test/windows/e2e.ps1` (after `LOCK ZIG build -j2`)
- Run everything from the task's worktree root.

## Review Focus

1. **Closing things in every order:** last split of a tab, last tab of a window, last window; a shell `exit` while its close-confirm dialog is open; closing a tab whose surfaces stream output; closing from a keybind, the strip, Alt+F4 and the IPC. Expected: no use-after-free, focus lands on a live surface, the process ends only when the last window goes (and `quit-after-last-window-closed` allows it) → tests in Task 6a (`focusAfterRemove`), Task 6b (close decision; hide-before-teardown), Task 14 (`split-close` e2e), Task 21 (`windows-multi` e2e), Task 27 (`close-confirm` e2e incl. shell exit behind the dialog), Task 28 (`tray` e2e: last window closed → process stays, New Window / Quit from the tray), Task 29 (`close-tree`, `tab-close-tree`: the tab's console clients end, `start cmd` windows and GUI apps survive), Task 32 (`tab-drag`: drag out, drag back, Esc; the source window closes when emptied, process pids unchanged).
2. **Many and tiny:** 30 tabs (strip overflow), 16 panes, a 200×150 window, a split dragged to its minimum. Expected: no negative/zero-width rects except hidden leaves, the active tab always visible, no zero-size swap chain draw, no crash → Task 9 (`tiny bounds`, `rounding sums`), Task 10 (`overflow keeps active visible`), Task 14 (`split-many` e2e incl. closing 16 panes while 4 stream), Task 16 (drag clamp test).
3. **Single instance in the wild:** no server, a stale pipe, a server blocked in a modal dialog, two launches 50 ms apart, a request that outlives the client timeout, a squatted pipe name, an elevated instance, a `--working-directory` with spaces and Cyrillic, an owner instance of another build/class. Expected: the second launch either forwards and exits 0 within 2 s or runs standalone; never hangs, never reaches another class/session → Task 5 (pipe name, sanitize), Task 8 (busy/timeout/deadline/no-server/owner-check tests), Task 20 (`single-instance` e2e with `C:\…\Рабочая папка`).
4. **DPI with hidden state:** a DPI change while a tab is hidden, a split zoomed, the window maximized or fullscreen. Expected: every surface (hidden ones too) and the strip use the new scale; maximize stays within the new monitor's work area → Task 23 (unit + `dpi-sim` e2e with a hidden tab and a zoomed split).
5. **Custom frame behaves like a native window:** maximized window does not overflow the monitor, top-edge resize works when restored, double-click caption maximizes, Alt+Space opens the system menu, snap flyout on the maximize button, keyboard focus returns to the terminal after any strip click. Expected as on any Win11 app → Task 17 (`frame-hittest` e2e: NCHITTEST codes, maximized rect), Task 19 (focus after click).
6. **Latency (owner: lag in ReleaseFast too, worst in TUIs):** key echo in an idle shell; mouse-wheel scrolling and key navigation in `less`/`vim`; output→present; a key burst while 4 panes stream. Expected: the per-scenario thresholds of Task 36 on ReleaseFast and Debug, no backlog after a wheel burst, no frame-slot wait after an idle gap, no `draw_mutex` held across the slot wait, idle CPU unchanged → Task 36 (tracer, three e2e probes, ConPTY variants, baseline), Task 37 (fixes inside Ghostty), Task 40 (ConPTY mitigation when ConPTY is the floor), Task 14 (`split-many` pacing check).
7. **Drops and elevation:** files with spaces, quotes, `&`, Cyrillic, > 260 chars, 20 files at once, a folder; Git Bash vs pwsh vs cmd; an elevated Ghostty. Expected: one line of correctly quoted, space-separated paths delivered as a paste (bracketed when the shell enabled it), nothing executed; elevated instances neither accept nor send pipe requests across the boundary → Task 38 (`drop-files` e2e, quoting tests), Tasks 5/8 (elevation tests).

## Waves (parallelism)

≤ 3 tasks per wave; file sets inside a wave are strictly disjoint (checked against every task's `Files:` and the hot-file chains below). Task numbers are identities, not order: the table is the execution order.

| Wave | Tasks | Depends on |
|---|---|---|
| W1 | 36 latency measurement (key echo, TUI scroll/navigation, output→present; ConPTY variants) — **first task of M2** (owner, 2026-10-26) · 2 M2 skeleton (stubs, ids) · 3 action dispatch + coverage | — |
| W2 | 1 pkg/win32 extras (W2–W4 needs + empty modules) · 5 IPC protocol + Overrides · 6a Window/Tab/Surface model | — (1); 2 (5, 6a); 3 (6a) |
| W3 | 4 test infra · 6b close flow + feature hooks · 8 IPC transport | 36 (4); 6a (6b); 1+5 (8) |
| W4 | 11 IPC ops + pipe claim + test oracle · 37 latency fixes inside Ghostty · 7 pkg/win32 D2D + DirectWrite | 4+5+6b+8 (11); 1+4+36 (37); 1 (7) |
| W5 | 9 SplitLayout · 10 TabStrip model · 40 ConPTY latency mitigation (conditional on 36/37 evidence) | 2 (9, 10); 36+37 (40) |
| W6 | 12 chrome spike · 13 tabs · 14 splits (+ RAM probe) | 7 (12); 6b+11 (13); 6b+9+11+37 (14) |
| G1 | **Lead gate: RAM checkpoint** (ReleaseFast `one-surface`, `tabs`, `splits`, `zero-windows` rows from Task 14's probe; decision recorded in the ledger before W7, see Task 14) | 13, 14 |
| W7 | 15 theme + config reload · 30 re-parent-safe present target · 29 tab-close process semantics | 1+6b+11 (15); 6b+37 (30); 11+13+37 (29) |
| W8 | 17 custom frame · 18 chrome painter · 25 scrollbar | 6a+10+12+15 (17); 7+10+12+15 (18); 6b+30 (25) |
| W9 | 19 strip input + inline rename + `chrome-paint` e2e · 20 single-instance + performIpc · 21 multi-window | 13+17+18 (19); 8+11 (20); 13+30 (21) |
| W10 | 22 placement toggles · 23 per-monitor DPI · 16 divider drag + focus-follows-mouse | 17 (22); 17+18+25 (23); 14+19+37 (16) |
| W11 | 26 bell + taskbar progress · 27 TaskDialog confirmations · 24 resize overlay | 18 (26); 6b (27); 18 (24) |
| W12 | 28 tray + last-window lifecycle · 31 tab drag state machine + ghost | 15+20+21+27 (28); 18 (31) |
| W13 | 32 tab tear-off and re-dock · 38 file drop · 39 device loss with a resident process | 19+21+30+31 (32); 6b+11+19+26 (38); 28+30+37 (39) |
| W14 | 33 M2 e2e full run (alone) | all above |
| W15 | 34.n integration fixes (≤ 3 at a time, disjoint) | 33 |
| W16 | 35 RAM rows, screenshots, M2 acceptance (alone) | 34.* |

Hot-file chains (every file touched by more than one task; any file not listed has a single owner):
- apprt: `App.zig` 3→6a→6b→11→18→20→27→28→39; `Window.zig` 6a→6b→13→21→23→32; `Tab.zig` 6a→6b→14→16→32; `Surface.zig` 36→6a→6b→30→25→23; `Chrome.zig` 2→18; `strip_input.zig` 2→19→32; `mouse.zig` 36→37→16; `keyboard.zig` 36→37; `dialogs.zig` 2→27; `instance.zig` 2→8→20; `ipc/ops.zig` 2→11→28; `ipc/protocol.zig` 2→5; every other stub file of Task 2 → its one owner; `src/apprt/win32.zig` 2 only.
- actions: `app_actions.zig` 3→15→21→28; `window_actions.zig` 3→6a→13→19→22→26; `tab_actions.zig` 3→13→21; `split_actions.zig` 3→14; `surface_actions.zig` 3→6a→25.
- core: `src/config/Config.zig` 20→28; `src/termio/Exec.zig` 36→37→29; `src/pty.zig` 36→40; `src/os/windows.zig` 36→40; `src/build/SharedDeps.zig` 1→37 (37 only if its measurement selects the C-dependency lever).
- renderer: `src/renderer/D3D11.zig` 36→4→37→30→39; `d3d11/SwapChain.zig` 36→37→30; `d3d11/Frame.zig` 4→37; `d3d11/Device.zig` 4→39.
- bindings: `pkg/win32/main.zig` + `build.zig` 1→7; `uxtheme.zig` 1→15→18; `shell32.zig` 1→15→26→28→38; `comctl32.zig` 1→19→27; `winmm.zig` 1→26; `ole32.zig` 26→38; `user32.zig`, `kernel32.zig`, `advapi32.zig`, `dwmapi.zig`, `gdi32.zig` 1 only. A declaration found missing in a Task-1-only file during a later wave is reported to the lead, who appends it in a one-line commit between waves (never two tasks in one file in one wave).
- tests/docs: `test/windows/e2e/_common.ps1` 4→29→35; `e2e/close-tree.ps1` 4→29; `e2e/input-latency.ps1`, `e2e/tui-latency.ps1`, `e2e/output-latency.ps1`, `e2e/_latency.ps1`, `docs/windows/latency-baseline.csv` 36→37→40; `lib/Harness.psm1`, `README.md` 4→35; `measure-ram.ps1`, `docs/windows/ram-baseline.csv` 4→14→G1→35; `test/windows/lib/MouseInput.psm1` 17→19 (16, 32, 38 only use it); `test/windows/lib/GhosttyIpc.psm1` 11 only; `docs/windows/SPEC.md` 35 (+ lead rulings).

Private message ids (`messages.zig`, Task 2; M1 values unchanged): `WM_APP+1` `WM_GHOSTTY_WAKEUP` (msg window), `+2` `WM_GHOSTTY_CLIPBOARD_READ` (surface), `+3` `WM_GHOSTTY_QUIT_TIMER` (M1 constant, the timer itself is `WM_TIMER` id 1; kept reserved), `+4` `WM_GHOSTTY_QUIT` (msg window, M1 quit confirmation via `QuitGate`), `+5` `WM_GHOSTTY_IPC` (msg window), `+6` `WM_GHOSTTY_CLOSE_SURFACE` (top-level), `+7` `WM_GHOSTTY_CLOSE_TAB` (top-level), `+8` `WM_GHOSTTY_TITLE_EDIT_DONE` (top-level, consumed by `strip_input.handle`), `+9` `WM_GHOSTTY_TRAY` (tray window callback), `+10` `WM_GHOSTTY_DROP` (top-level, consumed by `drop.handle`), `+11..+15` reserved M3. There is no `WM_GHOSTTY_QUIT_CONFIRM`: every quit (keybind, tray, IPC) goes through M1's `WM_GHOSTTY_QUIT`.
Timer ids (`messages.zig`, per window class): msg window `1` quit timer (M1); `GhosttyTab` `1` divider-drag relayout (Task 16); `GhosttyResizeOverlay` `1` hide (Task 24); `GhosttyWindow` `1` reserved (strip auto-scroll during a tab drag, Task 32); `GhosttyDropHighlight` none.

---

### Task 1: `pkg/win32` Win32 extras for W2–W4 (+ the single-file hot spots) and scattered externs moved in

**Files:**
- Modify: `pkg/win32/user32.zig`, `pkg/win32/kernel32.zig`, `pkg/win32/dwmapi.zig`, `pkg/win32/gdi32.zig`, `pkg/win32/main.zig`, `pkg/win32/build.zig`, `pkg/win32/test_user32.zig`
- Create: `pkg/win32/advapi32.zig` (content below); `pkg/win32/shell32.zig`, `pkg/win32/comctl32.zig`, `pkg/win32/uxtheme.zig`, `pkg/win32/winmm.zig` (doc comment only — registered in `main.zig` and linked now, so later owners only append; see the bindings chain)
- Modify (extern moves only): `src/apprt/win32/util.zig` (RegGetValueW), `src/apprt/win32/clipboard.zig` (EnumClipboardFormats). The local externs in `mouse.zig` (SystemParametersInfoW, GetClassNameW) and `d3d11/SwapChain.zig` (WaitForSingleObjectEx, CloseHandle) are moved by Task 37, which owns both files in W4 (Task 36 holds them in W1, before these declarations exist).
- Modify: `src/build/SharedDeps.zig` Windows block (link list += `comctl32 shell32 uxtheme winmm d2d1 dwrite`; link the system libs only for artifacts that import `win32`, not for lib-vt consumers — M1 Task 5 minor)

**Interfaces:**
- Produces. Scope rule (pre-flight 15): the files that only Task 1 edits (`user32`, `kernel32`, `advapi32`, `dwmapi`, `gdi32`) get everything M2 needs from them now, because no later task may touch them; the separate DLL modules (`shell32`, `comctl32`, `uxtheme`, `winmm`, `ole32`) are filled by the task that first calls them (15, 18, 19, 26, 27, 28, 38).
  - `user32`: `SetParent GetParent GetAncestor IsZoomed IsIconic IsWindowVisible GetWindowPlacement SetWindowPlacement MonitorFromWindow MonitorFromPoint GetMonitorInfoW BeginDeferWindowPos DeferWindowPos EndDeferWindowPos SetScrollInfo GetScrollInfo ShowScrollBar FlashWindowEx RegisterWindowMessageW GetClassNameW SystemParametersInfoW SystemParametersInfoForDpi GetSystemMetricsForDpi EnumClipboardFormats MapWindowPoints GetDC ReleaseDC GetWindowTextW GetWindowTextLengthW RedrawWindow SetForegroundWindow AllowSetForegroundWindow ShowWindowAsync TrackMouseEvent(TME_NONCLIENT) GetSystemMetrics WindowFromPoint ChildWindowFromPointEx ChangeWindowMessageFilterEx MessageBeep EnumWindows GetWindowThreadProcessId`; menus and icons `CreatePopupMenu AppendMenuW TrackPopupMenuEx DestroyMenu LoadImageW DestroyIcon`; layered windows `UpdateLayeredWindow GetCapture`; types `WINDOWPLACEMENT MONITORINFO SCROLLINFO FLASHWINFO NCCALCSIZE_PARAMS BLENDFUNCTION`; constants `WM_NCCALCSIZE WM_NCHITTEST WM_NCMOUSEMOVE WM_NCMOUSELEAVE WM_NCLBUTTONDOWN WM_NCLBUTTONUP WM_NCLBUTTONDBLCLK WM_NCRBUTTONUP WM_NCACTIVATE WM_ACTIVATE WM_SETTINGCHANGE WM_THEMECHANGED WM_VSCROLL WM_MBUTTONUP WM_LBUTTONDBLCLK WM_CONTEXTMENU WM_SYSCOMMAND WM_WINDOWPOSCHANGED WM_ENTERSIZEMOVE WM_COMMAND WM_CAPTURECHANGED WM_QUERYENDSESSION WM_ENDSESSION WM_NULL`, all `HT*` codes, `SC_MINIMIZE SC_MAXIMIZE SC_RESTORE SC_CLOSE`, `SB_* SIF_* ESB_*`, `FLASHW_*`, `MONITOR_DEFAULTTONEAREST`, `SWP_FRAMECHANGED SWP_SHOWWINDOW SWP_HIDEWINDOW`, `HWND_TOPMOST HWND_NOTOPMOST`, `WS_POPUP WS_CLIPCHILDREN WS_VSCROLL WS_EX_TOOLWINDOW WS_EX_NOACTIVATE WS_EX_TOPMOST WS_EX_LAYERED WS_EX_TRANSPARENT`, `ES_AUTOHSCROLL`, `SM_CXFRAME SM_CYFRAME SM_CXPADDEDBORDER SM_CXSMICON`, `SPI_GETWHEELSCROLLLINES SPI_GETHIGHCONTRAST HIGHCONTRASTW HCF_HIGHCONTRASTON`, `MF_STRING MF_SEPARATOR TPM_RETURNCMD TPM_RIGHTBUTTON TPM_BOTTOMALIGN IMAGE_ICON LR_DEFAULTCOLOR`, `ULW_ALPHA AC_SRC_ALPHA GA_ROOT VK_ESCAPE`, `MSGFLT_ALLOW`, `CWP_SKIPINVISIBLE CWP_SKIPTRANSPARENT`, `MB_OK`.
  - `kernel32`: `CreateNamedPipeW ConnectNamedPipe DisconnectNamedPipe CreateFileW WaitNamedPipeW ReadFile WriteFile FlushFileBuffers GetOverlappedResult CancelIoEx CreateEventW SetEvent ResetEvent WaitForSingleObjectEx WaitForMultipleObjects CloseHandle GetCurrentProcessId ProcessIdToSessionId GetNamedPipeServerProcessId GetNamedPipeClientProcessId OpenProcess GetTickCount64 LocalFree GlobalMemoryStatusEx`; `OVERLAPPED SECURITY_ATTRIBUTES MEMORYSTATUSEX`; `PIPE_ACCESS_DUPLEX FILE_FLAG_OVERLAPPED FILE_FLAG_FIRST_PIPE_INSTANCE PIPE_TYPE_BYTE PIPE_READMODE_BYTE PIPE_WAIT PIPE_REJECT_REMOTE_CLIENTS PIPE_UNLIMITED_INSTANCES SECURITY_SQOS_PRESENT SECURITY_IDENTIFICATION PROCESS_QUERY_LIMITED_INFORMATION ERROR_PIPE_BUSY ERROR_PIPE_CONNECTED ERROR_IO_PENDING ERROR_FILE_NOT_FOUND ERROR_ACCESS_DENIED ERROR_BROKEN_PIPE ERROR_SEM_TIMEOUT WAIT_OBJECT_0 WAIT_TIMEOUT INFINITE GENERIC_READ GENERIC_WRITE OPEN_EXISTING`.
  - `advapi32`: `RegGetValueW OpenProcessToken GetTokenInformation ConvertSidToStringSidW ConvertStringSecurityDescriptorToSecurityDescriptorW EqualSid`, `TOKEN_QUERY`, `TokenUser TokenElevation`, `TOKEN_USER TOKEN_ELEVATION`, `SDDL_REVISION_1`, `HKEY_CURRENT_USER`, `RRF_RT_REG_DWORD`.
  - `dwmapi`: `DwmExtendFrameIntoClientArea DwmDefWindowProc DwmGetWindowAttribute`, `MARGINS`, `DWMSBT_AUTO=0 DWMSBT_NONE=1 DWMSBT_MAINWINDOW=2 DWMSBT_TRANSIENTWINDOW=3 DWMSBT_TABBEDWINDOW=4`, `DWMWA_CAPTION_COLOR`, `DWMWCP_*`.
  - `gdi32`: `CreateCompatibleDC CreateDIBSection SelectObject DeleteObject DeleteDC CreateSolidBrush FillRect`, `BITMAPINFO BITMAPINFOHEADER DIB_RGB_COLORS BI_RGB`.
  - Moved out of this task (pre-flight 15): `ShellExecuteW` and `SetWindowTheme` → Task 15; buffered paint → Task 18; window subclassing → Task 19; `ITaskbarList3`, `winmm`, `CoCreateInstance` → Task 26; `TaskDialogIndirect` → Task 27; `Shell_NotifyIconW` → Task 28; OLE drag-and-drop and `DragQueryFileW` → Task 38. The `zig cc` provenance tests for `TASKDIALOGCONFIG`, `ITaskbarList3`, `NOTIFYICONDATAW` move with them.
- [ ] **Step 1: Failing tests** in `pkg/win32/test_user32.zig`:
  ```zig
  test "win32 advapi32: current user SID string starts with S-1-5-" {}
  test "win32 advapi32: token elevation query succeeds" { // TokenElevation of the current process: call succeeds; value recorded, not asserted }
  test "win32 kernel32: named pipe loopback" { // CreateNamedPipeW(\\.\pipe\ghostty-test-<pid>, OVERLAPPED) + CreateFileW client; write 5 bytes, read 5 bytes; GetNamedPipeServerProcessId == own pid }
  test "win32 dwmapi: MARGINS size" { // 16 }
  test "win32 user32: BLENDFUNCTION and NCCALCSIZE_PARAMS sizes" { // 4 and 64 + 8 (x64; provenance comment from a throwaway zig cc program) }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 --build-file pkg/win32/build.zig` → FAIL (missing declarations).
- [ ] **Step 3: Implement** the declarations; replace the local externs in `util.zig` and `clipboard.zig` with the package ones (no behaviour change).
- [ ] **Step 4: Verify** package tests PASS; `LOCK ZIG build -j2` PASS; `LOCK ZIG build -j2 -Demit-lib-vt` PASS (lib-vt does not link the new system libs); the M1 I2 Linux recipe `LOCK ZIG build -j2 -Dtarget=x86_64-linux-gnu -Dapp-runtime=none` PASS (pre-flight 26); `grep -n 'extern "' src/apprt/win32/util.zig src/apprt/win32/clipboard.zig` → no output (the full grep is Task 37's check).
- [ ] **Step 5: Commit** `git commit -m "feat(win32): M2 Win32 bindings (pipes, tokens, DWM frame, layered windows, menus) and move local externs into pkg/win32"`

### Task 2: M2 skeleton — feature-module stubs, message ids, close kinds

**Files:**
- Create (stubs, exact contents per Interfaces): `src/apprt/win32/{geom,messages,Overrides,instance,SplitLayout,TabStrip,frame,Chrome,strip_input,title_edit,theme,placement,scrollbar,bell,taskbar,resize_overlay,tab_drag,drag_ghost,drop}.zig`, `src/apprt/win32/ipc/{protocol,Server,client,ops}.zig`
- Modify: `src/apprt/win32.zig` (test block imports every new file), `src/apprt/win32/dialogs.zig` (add `CloseKind`, `confirmCloseKind`). The present-target id seam (`PresentTarget.id`) moved to Task 36, which needs it in W1 for per-surface latency samples and owns `Surface.zig`/`D3D11.zig` in that wave.

**Interfaces:**
- Produces (later tasks replace bodies, never names or field types):
  ```zig
  // geom.zig (real)
  pub const Rect = struct { x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0,
      pub fn contains(r, px: i32, py: i32) bool; pub fn right(r) i32; pub fn bottom(r) i32;
      pub fn fromRECT(win32 RECT) Rect; pub fn toRECT(r) RECT; pub fn scale(v: i32, dpi: u32) i32 /* round(v*dpi/96) */ };
  // messages.zig (real): the message ids and the timer-id table listed above the task list. M1's ids are re-exported
  // with their M1 values (+1 wakeup, +2 clipboard read, +3 quit timer, +4 WM_GHOSTTY_QUIT); App.zig and clipboard.zig
  // are NOT edited here (Task 3 switches App.zig to these names; clipboard.zig keeps its constant, asserted equal).
  // Overrides.zig: data real, functions stubbed (Task 5)
  command: ?configpkg.Command = null, shell_integration: ?configpkg.Config.ShellIntegration = null,
  working_directory: ?[:0]const u8 = null, title: ?[:0]const u8 = null,
  pub const none: Overrides = .{};
  pub fn parse(arena: Allocator, args: []const []const u8) ParseError!Overrides;   // stub: .none
  pub fn apply(self: Overrides, config: *configpkg.Config) !void;                  // stub: no-op
  pub fn forwardable(args: []const []const u8) bool;                               // stub: false
  // TabStrip.zig: types real, compute/hitTest stubbed (Task 10)
  pub const Mode = enum { hidden, tabs_only, titlebar };
  pub const Part = union(enum) { nowhere, caption, resize_top, tab: usize, tab_close: usize, new_tab, minimize, maximize, close };
  pub const Metrics = struct { height: i32, tab_min_w: i32, tab_max_w: i32, tab_pad: i32, close_w: i32, new_tab_w: i32,
      caption_btn_w: i32, min_drag_w: i32, resize_band: i32, drag_threshold: i32, pub fn forDpi(dpi: u32) Metrics };
  pub const Layout = struct { mode: Mode = .hidden, show_tabs: bool = false, bounds: geom.Rect = .{},
      tabs: std.ArrayList(geom.Rect) = .empty, new_tab: ?geom.Rect = null, minimize: ?geom.Rect = null,
      maximize: ?geom.Rect = null, close: ?geom.Rect = null, caption: geom.Rect = .{}, title: ?geom.Rect = null,
      clip: geom.Rect = .{}, scroll: i32 = 0,
      pub fn compute(self: *Layout, alloc: Allocator, m: Metrics, width: i32, mode: Mode, show_tabs: bool, count: usize, active: usize) !void,
      pub fn hitTest(self: *const Layout, m: Metrics, x: i32, y: i32, maximized: bool) Part,
      pub fn deinit(self: *Layout, alloc: Allocator) void };
  pub const Drag = struct { tab: usize, start_x: i32, grab_dx: i32, active: bool = false, current: usize };
  // stub compute: bounds = {0,0,width, mode==.hidden ? 0 : m.height}, nothing else; hitTest → .nowhere
  // frame.zig (Task 17)
  pub const Decorations = enum { client, server, none };
  pub const State = struct { decorations: Decorations = .server, hover: TabStrip.Part = .nowhere, pressed: TabStrip.Part = .nowhere, nc_tracking: bool = false };
  pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT;  // stub: null
  pub fn apply(window: *Window) void;                                                  // stub: no-op
  pub fn stripMode(window: *const Window) TabStrip.Mode;  // stub: .hidden
  pub const Size = struct { w: i32, h: i32 };
  pub fn nonClientSize(window: *const Window) Size;  // window size minus content size: frame insets + strip height (pre-flight 9);
                                                     // stub: the M1 value, AdjustWindowRectExForDpi(style, ex_style, window.dpi) (Task 6a routes frameSize here)
  // Stub bodies may use only M1 `Window` fields (hwnd, app) plus `dpi`: Task 6a adds the rest in the next wave.
  // bell.zig (Task 26)
  pub fn decorateTitle(alloc: Allocator, title: []const u8, tab: *const Tab) ![:0]u8;  // stub: dupeZ(title); Task 13's refreshTitle calls it
  // drop.zig (Task 38)
  pub const ShellKind = enum { msys, wsl, pwsh, cmd };
  pub fn shellKindFor(command: ?configpkg.Command) ShellKind;     // stub: .cmd
  pub fn register(window: *Window) void;                          // stub: no-op (Task 6a calls it after CreateWindowExW)
  pub fn revoke(window: *Window) void;                            // stub: no-op (Task 6a calls it before DestroyWindow)
  pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT;  // stub: null (Task 6b dispatch chain)
  // Chrome.zig (Task 18): per-window painter state + process-wide resources
  pub fn paint(window: *Window, hdc: HDC, dirty: geom.Rect) void;  // stub: no-op (the class brush paints)
  pub fn invalidate(window: *Window) void;                          // stub: InvalidateRect(window.hwnd, null, FALSE); Task 18: strip bounds only
  pub fn deinitShared() void;                                       // stub: no-op
  // strip_input.zig (Task 19)
  pub const State = struct { drag: ?TabStrip.Drag = null, hover: TabStrip.Part = .nowhere, tracking: bool = false,
      drop_index: ?usize = null };   // drop_index: insertion marker drawn while another window's tab is dragged over this strip (Task 32)
  pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT;  // stub: null
  // theme.zig (Task 15)
  pub const Color = struct { r: u8, g: u8, b: u8, a: u8 = 255 };
  pub const Palette = struct { dark: bool, mica: bool, strip_bg: Color, tab_active_bg: Color, tab_hover_bg: Color,
      text: Color, text_inactive: Color, button_hover_bg: Color, button_pressed_bg: Color,
      close_hover_bg: Color = .{ .r = 0xC4, .g = 0x2B, .b = 0x1C }, close_hover_text: Color = .{ .r = 255, .g = 255, .b = 255 }, divider: Color };
  pub fn palette(window: *const Window) Palette;          // stub: fixed dark palette, mica = false
  pub fn applyToWindow(window: *Window) void;             // stub: M1 behaviour (DWMWA_USE_IMMERSIVE_DARK_MODE from util.systemUsesDarkTheme)
  pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT;  // stub: null
  pub fn schemeChanged(app: *App, scheme: apprt.ColorScheme) void;                     // stub: no-op
  // placement.zig (Task 22)
  pub const State = struct { fullscreen: bool = false, topmost: bool = false, saved_valid: bool = false,
      saved_rect: geom.Rect = .{}, saved_show_cmd: u32 = 0, saved_style: usize = 0,
      initial_size: ?struct { width: u32, height: u32 } = null };   // own fields, not WINDOWPLACEMENT: Task 1 adds that type in the same wave
  pub fn applyStartup(window: *Window) void;              // stub: no-op
  // scrollbar.zig (Task 25)
  pub const State = struct { total: u64 = 0, offset: u64 = 0, len: u64 = 0, enabled: bool = false };
  // taskbar.zig (Task 26)
  pub const State = struct { progress: ?terminal.osc.Command.ProgressReport = null };
  pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT;  // stub: null
  // resize_overlay.zig (Task 24)
  pub const State = struct { hwnd: ?HWND = null, armed: bool = false };
  pub fn notify(surface: *Surface, cols: u32, rows: u32) void;  // stub: no-op
  pub fn deinit(state: *State) void;                            // stub: no-op
  // dialogs.zig
  pub const CloseKind = enum { surface, tab, window, all_windows, app };
  pub fn confirmCloseKind(owner: HWND, kind: CloseKind) bool;   // M1 MessageBoxW with a kind-specific sentence
  ```
  `instance.zig`, `SplitLayout.zig`, `title_edit.zig`, `tab_drag.zig`, `drag_ghost.zig`, `ipc/*.zig`: doc comment only (owners create their API).
  This task does not edit `App.zig` (Task 3 owns it in W1; pre-flight 1).
- [ ] **Step 1: Failing tests** `"win32 skeleton: private message ids are unique and keep M1's values"` (all `messages.WM_GHOSTTY_*` distinct and in `WM_APP+1 … WM_APP+15`; `messages.WM_GHOSTTY_WAKEUP == App.WM_GHOSTTY_WAKEUP`, `messages.WM_GHOSTTY_QUIT == App.WM_GHOSTTY_QUIT`, `messages.WM_GHOSTTY_QUIT_TIMER == App.WM_GHOSTTY_QUIT_TIMER`, `messages.WM_GHOSTTY_CLIPBOARD_READ == clipboard.WM_GHOSTTY_CLIPBOARD_READ` — true before and after Task 3 makes App's names aliases; timer ids unique per class); `"win32 geom: rect contains and scale"` (`{10,10,20,20}` contains (10,10) not (30,30); `scale(40, 144) == 60`, `scale(1, 120) == 1`).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 skeleton"` and `"win32 geom"` → FAIL.
- [ ] **Step 3: Implement** stubs exactly as listed.
- [ ] **Step 4: Verify** PASS; `LOCK ZIG build -j2` PASS; `E2E -Milestone M1` is not available yet — run `powershell -NoProfile -File test/windows/e2e-m1.ps1 -Only startup,render` → PASS (dumps still found: Task 4 renames them, M1 index naming unchanged here).
- [ ] **Step 5: Commit** `git commit -m "feat(win32): M2 module skeleton, private message ids, close kinds"`

### Task 3: Action dispatch with full coverage classification

**Files:**
- Modify: `src/apprt/win32/App.zig` (`performAction` → `actions.perform`; move M1 arms out; the `WM_GHOSTTY_*` constants become aliases of `messages.zig` (pre-flight 1); test for wakeup re-arm — M1 Task 14 minor)
- Create: `src/apprt/win32/actions.zig`, `src/apprt/win32/actions/{app_actions,window_actions,tab_actions,split_actions,surface_actions}.zig`

**Interfaces:**
- Consumes: M1 `App`, `Window` (one surface), `mouse.refreshCursor`.
- Produces:
  ```zig
  // actions.zig
  pub fn perform(app: *App, target: apprt.Target, comptime action: apprt.Action.Key, value: apprt.Action.Value(action)) !bool;
  pub const Status = union(enum) { implemented, deferred: struct { milestone: []const u8, reason: []const u8 }, unsupported: []const u8 };
  pub fn status(comptime key: apprt.Action.Key) Status;   // comptime table, one entry per key
  ```
  Every arm calls one handler `fn(app: *App, target: apprt.Target, value) !bool` in the area file named below; M2 handlers are stubs returning `false` until their task. Deferred and unsupported arms `log.debug` and return `false`.

  | Area file (owner task) | Actions |
  |---|---|
  | `app_actions` | `quit` (M1 move: still posts `WM_GHOSTTY_QUIT`, whose `QuitGate` handler in `App.zig` stays the only quit path; Task 21 routes other quit sources to it, Task 27 swaps its dialog for `confirmCloseKind(.app)`), `new_window`, `close_all_windows`, `goto_window`, `present_terminal` (21); `reload_config`, `config_change`, `open_config`, `color_change` (15); `quit_timer` (M1 move → `app.startQuitTimer/stopQuitTimer`) |
  | `window_actions` | `close_window`, `initial_size`, `size_limit`, `cell_size` (M1 move; 6a adapts); `set_window_title` (13); `toggle_maximize`, `toggle_fullscreen`, `toggle_window_decorations`, `float_window`, `reset_window_size`, `resize_window` (22, delegating to `placement`); `prompt_title` (19, → `title_edit.prompt`); `ring_bell`, `progress_report` (26) |
  | `tab_actions` | `new_tab`, `close_tab`, `goto_tab`, `move_tab`, `set_tab_title`, `set_title` (M1 move), `copy_title_to_clipboard`, `pwd` (13); `move_tab_to_new_window` (21) |
  | `split_actions` | `new_split`, `goto_split`, `resize_split`, `equalize_splits`, `toggle_split_zoom` (14) |
  | `surface_actions` | `mouse_shape`, `mouse_visibility`, `render`, `show_child_exited` (M1 move; `show_child_exited` keeps returning false = core handles it per `wait-after-command`); `scrollbar` (25) |

  Deferred (milestone, reason): `toggle_quick_terminal`, `toggle_command_palette`, `inspector`, `render_inspector`, `export_terminal_io`, `desktop_notification`, `command_finished`, `mouse_over_link`, `open_url` (core's opener stays the fallback), `start_search`, `end_search`, `search_total`, `search_selected`, `key_sequence`, `key_table`, `renderer_health`, `readonly`, `toggle_background_opacity`, `toggle_visibility` → `"M3"` (SPEC §17 M3 list); `check_for_updates`, `show_on_screen_keyboard`, `secure_input`, `undo`, `redo` → `"M5"` (Windows extras / analogs of macOS-only features); `selection_changed` → `"post-v1"` (UI Automation). Unsupported: `toggle_tab_overview` ("no tab overview on Windows; not required by DECISIONS"), `show_gtk_inspector` ("GTK only").
- [ ] **Step 1: Failing tests** in `actions.zig`:
  ```zig
  test "win32 actions: every Action.Key is classified" { // inline for over @typeInfo(apprt.Action.Key).@"enum".fields: status(key) compiles; count == 70 }
  test "win32 actions: M2 scope list matches the plan" { // the 43 implemented keys above report .implemented; the 25 deferred report their milestone; the 2 unsupported report .unsupported }
  test "win32 app: wakeup re-arms after the queued message is handled" { // wakeup → drain one WM_GHOSTTY_WAKEUP via msgWndProc → wakeup posts again }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 actions"` → FAIL.
- [ ] **Step 3: Implement**; M1 behaviour of the moved arms is unchanged (they still use `window.surface`; Task 6a adapts them).
- [ ] **Step 4: Verify** PASS; `LOCK ZIG build -j2`; `powershell -NoProfile -File test/windows/e2e-m1.ps1 -Only startup,ctrl-c,shell-exit` → PASS.
- [ ] **Step 5: Commit** `git commit -m "refactor(win32): action dispatch table with coverage classification for every action"`

### Task 4: Test infrastructure — discovering runner, per-scenario class, dumps outside the context lock

**Files:**
- Create: `test/windows/e2e.ps1`
- Modify: `test/windows/e2e-m1.ps1` (thin wrapper: `& e2e.ps1 -Milestone M1 @PSBoundParameters`), the 19 M1 scenario scripts in `test/windows/e2e/` (one header line each; the latency scripts from Task 36 already carry their headers and are not touched), `test/windows/e2e/_common.ps1`, `test/windows/lib/Harness.psm1`, `test/windows/measure-ram.ps1`, `test/windows/README.md`, `docs/windows/ram-baseline.csv` (LF line endings only)
- Modify: `src/renderer/d3d11/Frame.zig`, `src/renderer/D3D11.zig` (dump: read back into a CPU buffer under the context lock, write the BMP after `drawFrameEnd` unlocks; file name `surface-<PresentTarget.id>.bmp`, headless index unchanged), `src/renderer/d3d11/Device.zig` (comptime `@sizeOf`/`@offsetOf` assert for `DXGI_ADAPTER_DESC` use — M1 Task 30 minor)

**Interfaces:**
- Consumes: Task 36 (`PresentTarget.id`).
- Produces:
  - Scenario header (first comment line of each `e2e/*.ps1`, `_*.ps1` excluded): `# e2e: milestone=M1 timeout=150 order=30 [surfaces=N]` (`surfaces` > 4 makes the runner call `Assert-FreeRam 2.5` before the scenario and, for a Debug exe, run it under the test-lock). The 19 M1 scripts (incl. `stream-integrity` from M1 Task 30b) get `milestone=M1` and orders 10…190 in the current `e2e-m1.ps1` order.
  - `e2e.ps1 [-Milestone M1|M2|all] [-Only a,b] [-EvidenceDir d]`: discovers scripts, sorts by `order`, keeps every M1 runner behaviour (GUI lock held for the run and handed down in `GHOSTTY_E2E_LOCK_ID`, clipboard backup/restore, per-scenario timeout kill, `results.txt`/`info.txt`); exit code `0` = no FAIL and ≥ 1 PASS, `1` = any FAIL, `2` = every scenario SKIPped (M1 Task 28 minor).
  - `Harness.psm1`: `New-GhosttyConfigText -Class <c> [-Extra <string>]` — the one config writer every script uses (`_common.ps1`, `measure-ram.ps1`, the spike's `run.ps1`); it always writes `class = …` (pre-flight 14). `Assert-FreeRam([double]$Gb)` (`GlobalMemoryStatusEx` via `Get-CimInstance Win32_OperatingSystem`; SKIP with the reason when below).
  - `_common.ps1`: `Start-E2eGhostty` appends `class = ghostty-e2e-<8 hex>` (fresh per scenario, stored in `$G.Class`) and `quit-after-last-window-closed = true` (scenarios that expect the process to end keep their meaning with the Windows default `false`; `-KeepDefaultQuit` omits it) to the config text and sets `GHOSTTY_WIN32_TEST_IPC=1`; `$G.Dump` = `surface-1.bmp`; `Get-DumpPath($G, [int]$SurfaceId)`; `-ExtraArgs [string[]]` passed to the exe; `-NoTestIpc` leaves `GHOSTTY_WIN32_TEST_IPC` unset; `-Env @{…}` extra environment for the child. The window is found with `EnumWindows` by class `GhosttyWindow` + pid (first visible one), not `$proc.MainWindowHandle`, which is ambiguous once several `GhosttyWindow`s or the unowned drag ghost exist (pre-flight 20); `Get-GhosttyWindows($G)` returns all of them in z-order.
  - `measure-ram.ps1`: same class isolation (`class = ghostty-ram-<hex>`) through `New-GhosttyConfigText`; CSV `commit` = `git rev-parse --short HEAD` at measure time plus `-dirty` when the tree is dirty (M1 Task 30 minor); LF output.
- [ ] **Step 1: Failing test** `"d3d11 frame: dump is written after the context lock is released"` — fixture with a dump dir: a second thread blocks on `device.lockContext()` while frame 1 completes; assert it acquires the lock before the BMP file exists (the file appears after `drawFrameEnd`), and the file is `surface-7.bmp` when `PresentTarget.id = 7`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dapp-runtime=none -Dtest-filter="d3d11 frame"` → FAIL.
- [ ] **Step 3: Implement** renderer change and scripts.
- [ ] **Step 4: Verify** PASS; `LOCK ZIG build -j2`; `E2E -Milestone M1` → 19 PASS (or SKIP when not interactive, exit 2); `E2E -Only input-latency,tui-latency,output-latency` discovers Task 36's scripts (record-only until Task 37); `powershell -NoProfile -File test/windows/e2e-m1.ps1 -Only render` → PASS.
- [ ] **Step 5: Commit** `git commit -m "test(windows): discovering e2e runner, per-scenario instance class, frame dumps outside the context lock"`

### Task 5: IPC wire protocol and new-surface overrides (pure)

**Files:** Modify (replace stubs) `src/apprt/win32/ipc/protocol.zig`, `src/apprt/win32/Overrides.zig`.

**Interfaces:**
- Consumes: Task 2 stubs; GTK `src/apprt/gtk/class/Overrides.zig` (semantics of `parse`) and `src/apprt/gtk/class/surface.zig` (`applyCommandOverrides`, working-directory finalize, ~3570-3585) for `apply`.
- Produces:
  ```zig
  // ipc/protocol.zig — std only, no other imports (tmux.exe imports it as a module in M4)
  pub const version: u32 = 1;
  pub const max_frame: u32 = 16 << 20;            // wire limit (M4 tmux payloads)
  pub const max_request_m2: u32 = 64 << 10;       // what the M2 server accepts: JSON is parsed on the UI thread (pre-flight 17)
  pub fn writeFrame(w: *std.Io.Writer, payload: []const u8) !void;       // u32 LE length + bytes
  pub fn readFrame(r: *std.Io.Reader, alloc: Allocator) ![]u8;          // error.FrameTooLarge, error.EndOfStream
  pub const Code = enum(u8) { ok = 0, failed = 1, bad_request = 2, version_mismatch = 3 };
  pub const Request = struct { v: u32, op: []const u8, args: []const []const u8 = &.{}, core_surface: []const u8 = "0",
      surface: u32 = 0, window: u32 = 0, action: []const u8 = "", dpi: u32 = 0, scheme: []const u8 = "",
      deadline_ms: u64 = 0 };   // GetTickCount64() value after which the server must not act; 0 = none (pre-flight 6)
  pub fn expired(req: Request, now_ms: u64) bool;  // deadline_ms != 0 and now_ms > deadline_ms
  pub fn parseRequest(arena: Allocator, bytes: []const u8) error{ BadRequest, OutOfMemory }!Request; // unknown fields ignored
  pub fn encodeRequest(alloc: Allocator, req: Request) ![]u8;
  pub fn encodeResponse(alloc: Allocator, code: Code, stdout: []const u8, stderr: []const u8, data_json: ?[]const u8) ![]u8;
  pub const Response = struct { code: Code, stdout: []const u8, stderr: []const u8, data_json: ?[]const u8 };
  pub fn parseResponse(arena: Allocator, bytes: []const u8) !Response;
  pub fn sanitizeClass(buf: []u8, class: []const u8) []const u8;  // [A-Za-z0-9._-] kept, others '_', max 80 bytes
  pub fn pipeName(buf: []u8, sid: []const u8, session: u32, class: []const u8, elevated: bool) ![]const u8;
      // "\\\\.\\pipe\\ghostty-<sid>-<session>-<sanitized>", plus "-admin" when elevated (pre-flight 2)
  ```
  Ops (SPEC §18.5): `new-window` {args}, `new-tab` {core_surface, args}, `toggle-quick-terminal`; test-only (SPEC §18.8) `state`, `action` {surface, action}, `dpi` {window, dpi}, `color-scheme` {scheme}. Response `{"v":1,"code":N,"stdout":"…","stderr":"…","data":<json>|null}`.
  `Overrides.parse` accepts `--working-directory=`, `--title=`, `--command=`, `--shell-integration=`, and `-e <argv…>` exactly like GTK (used by `performIpc`, keybinds and the `new-tab` op). `forwardable(args)` = there are no args, or every arg is `--working-directory=…`: the owner's rule "a launch with arguments starts a separate process", with the one exception Explorer's "Open Ghostty here" needs (pre-flight 8; SPEC §18.6 amended). A command (`--command=`, `-e`) is never forwarded, so no pipe request makes another process run a program (pre-flight 2).
- [ ] **Step 1: Failing tests**
  ```zig
  test "win32 ipc protocol: frame roundtrip and limits" { // "{}" roundtrip; length 16 MiB + 1 → error.FrameTooLarge; truncated header → error.EndOfStream }
  test "win32 ipc protocol: request parse ignores unknown fields" { // {"v":1,"op":"new-window","args":["--title=a"],"zzz":3} → op/args }
  test "win32 ipc protocol: bad request" { // "not json" and {"op":1} → error.BadRequest }
  test "win32 ipc protocol: response with data" { // encodeResponse(.ok, "", "", "{\"a\":1}") parses back with data_json "{\"a\":1}" }
  test "win32 ipc protocol: pipe name has the elevation marker" { // elevated = true → ends with "-admin"; false → no marker }
  test "win32 ipc protocol: deadline" { // 0 never expires; 1000 expired at 1001, not at 1000; field roundtrips through encode/parse }
  test "win32 ipc protocol: pipe name sanitizes class" { // ("S-1-5-21-1", 1, "com.mitchellh.ghostty", false) → \\.\pipe\ghostty-S-1-5-21-1-1-com.mitchellh.ghostty; class "a b/ж" → "a_b___" (UTF-8 bytes each '_'); 200-byte class → 80 }
  test "win32 overrides: working directory with spaces and Cyrillic" { // "--working-directory=C:\\Users\\Анна Ли\\x y" kept verbatim }
  test "win32 overrides: -e collects the rest" { // {"-e","vim","a b"} → command direct {"vim","a b"} }
  test "win32 overrides: forwardable" { // {"--working-directory=C:\\a b"} true; {} true; {"--title=x"} false; {"--command=x"} false; {"--font-size=20"} false; {"-e","x"} false }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 ipc protocol"` and `"win32 overrides"` → FAIL.
- [ ] **Step 3: Implement** with `std.json` (parse into the struct with `ignore_unknown_fields`); `apply` mirrors GTK.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): IPC frame/JSON protocol and new-surface overrides"`

### Task 6a: Window → Tab → SplitTree(Surface) model with refcounted surfaces (one tab)

Split from revision 1's Task 6 (about 900 lines; pre-flight 15). 6a builds the object model and keeps M1's close behaviour; 6b replaces the close flow and wires the feature hooks.

**Files:**
- Create: `src/apprt/win32/Tab.zig`
- Modify: `src/apprt/win32/Window.zig`, `src/apprt/win32/Surface.zig`, `src/apprt/win32/App.zig`, `src/apprt/win32/actions/window_actions.zig`, `src/apprt/win32/actions/surface_actions.zig`

**Interfaces:**
- Consumes: Task 2 stubs (`frame.nonClientSize`, `frame.apply`, `theme.applyToWindow`, `placement`, `TabStrip`, `Overrides`, `drop.register/revoke/shellKindFor`), Task 3 area files.
- Produces (consumed by Tasks 6b, 11, 13–32, 38):
  ```zig
  // Surface.zig
  pub const Tree = SplitTree(Surface);
  pub const class_name: [:0]const u16;                                  // now pub (mouse.zig reuses it, Task 16)
  pub const CreateOptions = struct { parent: ?*CoreSurface = null, overrides: Overrides = .none, context: apprt.surface.NewSurfaceContext };
  pub fn create(tab: *Tab, opts: CreateOptions) !*Surface;  // refs = 0; config = apprt.surface.newConfig + overrides.apply + font-size inheritance (window-inherit-font-size, as GTK font_size_request);
                                                            // content scale from tab.window.dpi (never GetDpiForWindow; pre-flight 16)
  pub fn ref(self: *Surface, alloc: Allocator) Allocator.Error!*Surface; // SplitTree view contract
  pub fn unref(self: *Surface, alloc: Allocator) void;                  // destroy() at 0
  pub fn eql(a: *const Surface, b: *const Surface) bool;
  // new fields: tab: *Tab, refs: u32, bell_ringing: bool = false, scrollbar: scrollbar.State = .{},
  //   shell_kind: drop.ShellKind (= drop.shellKindFor(effective config command), Task 38 consumes)
  // focus-in sets tab.focused = self, clears bell_ringing, Chrome.invalidate(window); applySize calls resize_overlay.notify(self, grid cols, rows) after a successful sizeCallback
  // Tab.zig
  pub const CreateOptions = struct { parent: ?*CoreSurface = null, overrides: Overrides = .none, context: apprt.surface.NewSurfaceContext = .tab };
  window: *Window, hwnd: HWND /* class GhosttyTab, WS_CHILD|WS_CLIPCHILDREN|WS_CLIPSIBLINGS */, tree: Surface.Tree,
  focused: ?*Surface, title_override: ?[:0]u8, id: u32,
  pub fn create(window: *Window, opts: CreateOptions) !*Tab;    // container + first surface
  pub fn destroy(self: *Tab) void;                              // tree.deinit releases every surface
  pub fn focusedSurface(self: *Tab) ?*Surface;                  // focused if still in tree, else first leaf
  pub fn focus(self: *Tab) void;
  pub fn setVisible(self: *Tab, visible: bool) void;            // ShowWindow + occlusionCallback per surface; layout on show
  pub fn layout(self: *Tab) void;                               // this task: the single leaf fills the container
  pub fn replaceTree(self: *Tab, tree: Surface.Tree) void;      // deinit old, store, layout
  pub fn removeSurface(self: *Tab, s: *Surface) void;           // focusAfterRemove, tree.remove, empty → window.removeTab(self)
  pub fn title(self: *const Tab) []const u8;                    // title_override orelse focused surface title orelse "Ghostty"
  pub fn bellRinging(self: *const Tab) bool;
  pub fn needsConfirmClose(self: *const Tab) bool;              // any surface core.needsConfirmQuit()
  pub fn setWindow(self: *Tab, window: *Window) void;           // SetParent + every surface.window = window (Task 32 adds rescale + bumpPresentTarget)
  pub fn focusAfterRemove(comptime T: type, tree: *const T, at: T.Node.Handle, alloc: Allocator) !?T.Node.Handle; // previous_wrapped else next_wrapped, never `at`
  // Window.zig
  pub const CreateOptions = struct { parent: ?*CoreSurface = null, overrides: Overrides = .none, first_tab: bool = true };
  hwnd, app, id: u32, tabs: std.ArrayList(*Tab), active_tab: usize, dpi: u32 /* read once at creation, then only WM_DPICHANGED */,
  title_override: ?[:0]u8, strip: TabStrip.Layout, strip_input: strip_input.State, frame: frame.State, placement: placement.State,
  taskbar: taskbar.State, overlay: resize_overlay.State, size_limit, cell_size, confirming_close: bool, close_confirmed: bool,
  pub fn create(app: *App, opts: CreateOptions) !*Window;  // hidden; style WS_OVERLAPPEDWINDOW|WS_CLIPCHILDREN; theme.applyToWindow, frame.apply, drop.register
  pub fn show(self: *Window) void;                         // placement.applyStartup then ShowWindow
  pub fn activeTab(self: *Window) ?*Tab;
  pub fn addTab(self: *Window, opts: Tab.CreateOptions) !*Tab;  // this task: append + select
  pub fn selectTab(self: *Window, index: usize) void;           // hide old, show new, focus, refreshTitle, layout strip
  pub fn removeTab(self: *Window, tab: *Tab) void;              // destroy; select neighbour; none left → close the window (M1 path here, requestClose in 6b)
  pub fn tabIndex(self: *const Window, tab: *const Tab) ?usize;
  pub fn showTabs(self: *const Window) bool;                    // this task: tabs.len > 1 (Task 13 applies window-show-tab-bar)
  pub fn layout(self: *Window) void;  // m = TabStrip.Metrics.forDpi(dpi); strip.compute(width, frame.stripMode(self), showTabs(), …); content = client below strip.bounds; active container SetWindowPos; Chrome.invalidate
  pub fn contentRect(self: *const Window) geom.Rect;
  pub fn refreshTitle(self: *Window) void;                      // SetWindowTextW(title_override orelse active tab title)
  pub fn needsConfirmClose(self: *const Window) bool;
  pub fn findSurface(self: *Window, id: u32) ?*Surface;
  pub fn applyDpi(self: *Window, dpi: u32, suggested: ?win32.foundation.RECT) void; // M1 logic moved; Task 23 fixes ordering
  // frameSize() is deleted: initial_size, size_limit (WM_GETMINMAXINFO) and cell-size math use frame.nonClientSize(self) (pre-flight 9)
  // App.zig: windows: ArrayList(*Window), last_active: ?*Window, pub fn windowFor(core: *CoreSurface) ?*Window, pub fn surfaceFor(core) ?*Surface (= core.rt_surface)
  ```
  The window-procedure dead `SIZE_MINIMIZED` child branch goes away; `Window.create`'s error path removes itself by pointer (M1 Task 14/21 minors). Area handlers now route through `target.surface.rt_surface` (`mouse_shape` etc. act on that surface, not `window.surface`). `drop.revoke(window)` runs before `DestroyWindow`.
- [ ] **Step 1: Failing tests**
  ```zig
  test "win32 tab: focus after removing a leaf" { // TestView tree A | (B / C): remove B → A; remove A (first leaf) → B; single leaf → null }
  test "win32 window: content size round-trips through nonClientSize" { // pure helper windowSizeFor(content {800,600}, nc {16,39}) == {816,639} and contentSizeFor back; min track size = size_limit + nc }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 tab"` and `"win32 window"` → FAIL.
- [ ] **Step 3: Implement.** Destroy order stays SPEC §6.4 (surfaces before their container, containers before the top-level).
- [ ] **Step 4: Verify** PASS; `LOCK ZIG build -j2`; `powershell -NoProfile -File test/windows/e2e-m1.ps1` → all 19 PASS (the discovering runner arrives with Task 4 in W3; pre-flight 3a). Regression gate on ReleaseFast: close-tree, shell-exit, close-while-streaming, resize-while-streaming, resize.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): window/tab/split-tree model with refcounted surfaces"`

### Task 6b: Posted close flow, close kinds, feature-hook dispatch, hide-before-teardown

**Files:**
- Modify: `src/apprt/win32/Window.zig`, `src/apprt/win32/Tab.zig`, `src/apprt/win32/Surface.zig`, `src/apprt/win32/App.zig`

**Interfaces:**
- Consumes: Task 6a model; Task 2 stubs (`frame`, `strip_input`, `theme`, `taskbar`, `drop`, `Chrome`, `messages`, `dialogs.confirmCloseKind`).
- Produces:
  ```zig
  // Surface.zig: close(process_active) posts messages.WM_GHOSTTY_CLOSE_SURFACE to window.hwnd (wparam = id, lparam = process_active)
  // Window.zig
  pub fn requestClose(self: *Window, confirmed: bool) void;     // sets close_confirmed, posts WM_CLOSE (replaces M1's spoofable wparam marker)
  pub fn closeDecision(confirmed: bool, needs_confirm: bool) enum { close, ask };
  pub fn beginTeardown(self: *Window) void;                     // SW_HIDE the top-level first, then destroy tabs (pre-flight 13)
  // wndProc dispatch order: frame.handle → strip_input.handle → theme.handle → taskbar.handle → drop.handle → own cases; WM_PAINT → Chrome.paint;
  // WM_ACTIVATE tracks app.last_active; WM_GHOSTTY_CLOSE_SURFACE / WM_GHOSTTY_CLOSE_TAB / WM_CLOSE use closeDecision + dialogs.confirmCloseKind
  //   (confirming_close guard incl. Surface.close — M1 Task 21 minor); every dialog re-checks that its window/tab/surface survived the loop
  // Tab.zig: closing a tab hides its container (SW_HIDE) before Surface.destroy joins renderer/IO threads, so a 16-pane close is instant to the eye
  // App.zig: terminate() no longer spins on a failing DestroyWindow (M1 Task 14 minor); quit keeps M1's WM_GHOSTTY_QUIT + QuitGate
  ```
- [ ] **Step 1: Failing tests**
  ```zig
  test "win32 window: close decision" { // (true, true) → close; (false, true) → ask; (false, false) → close }
  test "win32 window: hook chain stops at the first handler" { // table-driven over a fake hook list: first non-null result wins, later hooks not called }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 window"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** PASS; `LOCK ZIG build -j2`; `powershell -NoProfile -File test/windows/e2e-m1.ps1` → all PASS (close-tree, shell-exit, close-while-streaming on ReleaseFast).
- [ ] **Step 5: Commit** `git commit -m "feat(win32): posted close flow with close kinds, feature hook dispatch, hide before teardown"`

### Task 7: `pkg/win32` Direct2D + DirectWrite bindings

**Files:** Create `pkg/win32/d2d1.zig`, `pkg/win32/dwrite.zig`, `pkg/win32/test_d2d.zig`; Modify `pkg/win32/main.zig`, `pkg/win32/build.zig`.

**Interfaces:**
- Consumes: Task 1 (`gdi32` DIB functions).
- Produces: `d2d1`: `D2D1CreateFactory` (single-threaded), `ID2D1Factory` (full slots; typed `CreateDCRenderTarget CreateHwndRenderTarget`), `ID2D1RenderTarget` (full slots; typed `CreateSolidColorBrush Clear FillRectangle FillRoundedRectangle DrawLine DrawTextLayout PushAxisAlignedClip PopAxisAlignedClip SetTextAntialiasMode BeginDraw EndDraw SetTransform`), `ID2D1DCRenderTarget.BindDC`, `ID2D1HwndRenderTarget.Resize`, `ID2D1SolidColorBrush.SetColor`, structs `D2D1_RENDER_TARGET_PROPERTIES D2D1_PIXEL_FORMAT D2D1_COLOR_F D2D1_RECT_F D2D1_ROUNDED_RECT D2D1_HWND_RENDER_TARGET_PROPERTIES D2D1_MATRIX_3X2_F`, enums (`D2D1_ALPHA_MODE_PREMULTIPLIED`, `D2D1_RENDER_TARGET_TYPE_SOFTWARE/DEFAULT`, `D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE`); `dwrite`: `DWriteCreateFactory`, `IDWriteFactory` (typed `CreateTextFormat CreateTextLayout CreateEllipsisTrimmingSign`), `IDWriteTextFormat` (typed `SetTextAlignment SetParagraphAlignment SetWordWrapping SetTrimming`), `IDWriteTextLayout` (typed `GetMetrics SetMaxWidth`), `IDWriteInlineObject`, `DWRITE_TRIMMING DWRITE_TEXT_METRICS`, enums.
- [ ] **Step 1: Failing tests** in `test_d2d.zig`:
  ```zig
  test "win32 d2d: vtable slot counts" { // ID2D1Factory 17, ID2D1RenderTarget 57, ID2D1DCRenderTarget 58, IDWriteFactory 24, IDWriteTextFormat 28 — recount against d2d1.h / dwrite.h of SDK 10.0.26100 and fix the numbers here if the header differs }
  test "win32 d2d: DC render target draws into a premultiplied DIB" {
      // 64x32 top-down 32bpp DIB, software DC target, Clear(0,0,0,0), FillRectangle(0,0,16,32, opaque red), DrawTextLayout("Ab", Segoe UI 14) at x=24
      // pixel (8,16) == BGRA {0,0,255,255}; pixel (62,2).a == 0; some pixel in x∈[24,60) has a > 0
  }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 --build-file pkg/win32/build.zig` → FAIL.
- [ ] **Step 3: Implement**; link `d2d1 dwrite` in the package build.
- [ ] **Step 4: Run** → PASS (all package tests).
- [ ] **Step 5: Commit** `git commit -m "feat(win32): Direct2D and DirectWrite bindings with a headless DC render test"`

### Task 8: IPC transport — pipe server thread, client, per-user/elevation pipe name, peer checks

**Files:** Modify (replace stubs) `src/apprt/win32/ipc/Server.zig`, `src/apprt/win32/ipc/client.zig`, `src/apprt/win32/instance.zig`.

**Interfaces:**
- Consumes: Task 1 (kernel32/advapi32), Task 5 (`protocol.readFrame/writeFrame/pipeName/expired`, `max_request_m2`).
- Produces:
  ```zig
  // instance.zig (Task 20 adds the single-instance decision)
  pub fn currentUserSid(alloc: Allocator) ![]u8;                  // "S-1-5-…" (OpenProcessToken/TokenUser/ConvertSidToStringSidW)
  pub fn isElevated() bool;                                       // TokenElevation of the current process (cached)
  pub fn defaultClass() []const u8;                               // "com.mitchellh.ghostty", Debug builds "com.mitchellh.ghostty-debug"
  pub fn pipeNameFor(alloc: Allocator, class: ?[]const u8) ![:0]u16; // protocol.pipeName(sid, ProcessIdToSessionId(GetCurrentProcessId()), class orelse defaultClass(), isElevated())
  pub fn peerMatches(pid: u32) bool;                              // OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION) → token user SID == own SID and TokenElevation == own
  // ipc/Server.zig
  pub const Pending = struct { request: []u8, response: ?[]u8 = null, done: HANDLE, refs: std.atomic.Value(u8) = .init(2) };
  pub fn claim(alloc: Allocator, name: [:0]const u16) error{ AddressInUse, SecurityFailed, Unexpected, OutOfMemory }!*Server; // creates the FIRST_PIPE_INSTANCE now (App.init, Task 11)
  pub fn start(self: *Server, msg_hwnd: HWND) !void;  // starts the IPC thread; clients that connected before this wait in the pipe
  pub fn stop(self: *Server) void;               // quit event, CancelIoEx, join, completes every outstanding Pending (mutex-guarded list) with code 1
  pub fn complete(pending: *Pending, response: []u8) void;   // UI thread: store, SetEvent, release ref
  pub fn release(pending: *Pending, alloc: Allocator) void;  // last ref frees
  // ipc/client.zig
  pub const Error = error{ NoServer, NotOurServer, Timeout, BrokenPipe, ProtocolError, OutOfMemory };
  pub fn request(alloc: Allocator, name: [:0]const u16, payload: []const u8, timeout_ms: u32) Error![]u8;
  ```
  Server: first instance with `FILE_FLAG_FIRST_PIPE_INSTANCE` (failure `ERROR_ACCESS_DENIED` → `error.AddressInUse`), `PIPE_TYPE_BYTE|PIPE_READMODE_BYTE|PIPE_REJECT_REMOTE_CLIENTS`, SDDL `D:P(A;;GA;;;<sid>)`, plus `S:(ML;;NW;;;HI)` when elevated so medium-integrity processes cannot open it (pre-flight 2). One IPC thread (64 KiB stack): overlapped connect; `GetNamedPipeClientProcessId` → `peerMatches` (same user and same elevation; mismatch → `code 1 "peer rejected"`, disconnect); read one frame (≤ 2 s, > `max_request_m2` → `bad_request` and disconnect); post `WM_GHOSTTY_IPC` (lparam = `*Pending`) — if `PostMessageW` fails (queue full) answer `code 1` at once and never wait (pre-flight 6); wait `done` or quit (no timeout; a modal UI keeps dispatching posted messages); write the response frame, flush, disconnect. A second listening instance is created as soon as a client connects, so a concurrent client connects and waits for its turn. The UI-thread op handler (Task 11) answers `code 1 "expired"` and does nothing when `protocol.expired(req, GetTickCount64())`.
  Client: `CreateFileW` with `SECURITY_SQOS_PRESENT|SECURITY_IDENTIFICATION` (the server cannot impersonate the caller), `WaitNamedPipeW` retry on `ERROR_PIPE_BUSY` until `timeout_ms`; `ERROR_FILE_NOT_FOUND` → `NoServer`; then `GetNamedPipeServerProcessId` → `peerMatches` before writing anything (a squatter owned by another user or at another integrity level → `NotOurServer`, nothing sent; pre-flight 7); `AllowSetForegroundWindow(pid)`; every request carries `deadline_ms = GetTickCount64() + timeout_ms - 250`, and the client waits `timeout_ms`, so a request the server picks up late is refused by the server instead of executed after the client gave up (pre-flight 6).
- [ ] **Step 1: Failing tests** (real pipes named `…-test-<pid>-<n>`; a test message-only window plays the UI thread, pumping `WM_GHOSTTY_IPC` and answering `{"echo":<request>}`, honouring `expired`)
  ```zig
  test "win32 ipc server: request roundtrip" {}
  test "win32 ipc server: second claim on the same name is AddressInUse" {}
  test "win32 ipc server: client connected before start() is answered" { // claim, client connects and writes, then start() → answered (pre-flight 5) }
  test "win32 ipc server: two concurrent clients are both answered in order" {}
  test "win32 ipc client: no server" { // NoServer within 50 ms }
  test "win32 ipc client: busy server times out and the late request is not executed" { // UI blocks 600 ms; client timeout 300 ms → Timeout; after the UI resumes the handler sees expired → no echo side effect counted; stop() completes everything without leaking (testing allocator) }
  test "win32 ipc server: post failure answers at once" { // test hook makes PostMessageW fail → client gets code 1 within 100 ms; the next client is still served }
  test "win32 ipc server: oversized frame is answered with bad_request and disconnected" { // 64 KiB + 1 }
  test "win32 ipc: elevation mismatch is rejected" { // test hook overrides isElevated() on the server side → client gets code 1, request not posted }
  test "win32 instance: pipe name has sid, session, class and elevation marker" { // starts with \\.\pipe\ghostty-S-1-5-, contains -<session>-com.mitchellh.ghostty; ends with -admin iff isElevated() }
  test "win32 instance: peerMatches own pid" { // true for GetCurrentProcessId(); false for pid 4 (System) }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 ipc"` and `"win32 instance"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS, 3 consecutive runs (no flake).
- [ ] **Step 5: Commit** `git commit -m "feat(win32): named-pipe IPC server and client with per-user/session/class/elevation names and peer checks"`

### Task 9: SplitLayout — rectangles, dividers and drag ratios from a SplitTree (pure)

**Files:** Modify (replace stub) `src/apprt/win32/SplitLayout.zig`.

**Interfaces:**
- Consumes: core `SplitTree` (`nodes`, `zoomed`, `Split{layout, ratio, left, right}`), `geom.Rect`.
- Produces:
  ```zig
  pub fn Layout(comptime Tree: type) type { return struct {
      pub const Leaf = struct { handle: Tree.Node.Handle, view: *Tree.View, rect: geom.Rect, visible: bool };
      pub const Divider = struct { split: Tree.Node.Handle, layout: Tree.Split.Layout, rect: geom.Rect, span: geom.Rect };
      leaves: []Leaf, dividers: []Divider,
      pub fn compute(alloc: Allocator, tree: *const Tree, bounds: geom.Rect, gap: i32) !@This();
      pub fn deinit(self: *@This(), alloc: Allocator) void;
      pub fn leafFor(self: *const @This(), view: *const Tree.View) ?Leaf;
      pub fn dividerAt(self: *const @This(), x: i32, y: i32) ?usize;
  }; }
  pub fn ratioForDrag(layout_kind: enum { horizontal, vertical }, span: geom.Rect, gap: i32, pos: i32, min_px: i32) f16; // clamp so both sides ≥ min_px
  pub fn resizeRatio(direction: enum { left, right, up, down }, amount: u16, bounds: geom.Rect) f16; // GTK split_tree.zig resize: ±amount/width|height, clamp [-1,1]
  pub fn gapPx(dpi: u32) i32;   // geom.scale(4, dpi), min 1
  ```
  Algorithm: a split of span length L gives the left/top child `floor((L - gap) * ratio)` px, the gap, the remainder to the right/bottom child (sizes sum to L exactly); a child size below 0 clamps to 0. Zoomed tree: the zoomed leaf gets `bounds`, every other leaf `visible = false`, no dividers.
- [ ] **Step 1: Failing tests** (local `TestView` with `ref/unref/eql`)
  ```zig
  test "win32 splitlayout: single leaf fills" {}
  test "win32 splitlayout: horizontal 0.5 with gap 4 in 1001 px" { // left w 498, divider x 498 w 4, right x 502 w 499 }
  test "win32 splitlayout: rounding sums to bounds for nested splits" { // 3 levels, random ratios 0.1..0.9 → leaves tile bounds minus dividers exactly, no overlap }
  test "win32 splitlayout: tiny bounds produce no negative sizes" { // bounds 3x3, gap 4 → every w,h ≥ 0 }
  test "win32 splitlayout: zoom hides siblings" {}
  test "win32 splitlayout: divider hit and drag ratio clamp" { // dividerAt on gap → index; ratioForDrag beyond span end → (L-gap-min)/(L-gap) }
  test "win32 splitlayout: resizeRatio matches GTK" { // right 100 in 1000 → 0.1; up 50 in 500 → -0.1; 5000 → 1 }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 splitlayout"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): split layout geometry over the core SplitTree"`

### Task 10: TabStrip — strip geometry, hit testing, drag reorder (pure)

**Files:** Modify (replace stub bodies) `src/apprt/win32/TabStrip.zig`.

**Interfaces:**
- Consumes: Task 2 types (unchanged).
- Produces: real `Metrics.forDpi` (at 96 dpi: `height 40, tab_min_w 72, tab_max_w 240, tab_pad 10, close_w 28, new_tab_w 40, caption_btn_w 46, min_drag_w 48, resize_band 6, drag_threshold 4`, each `geom.scale`d), `Layout.compute`, `Layout.hitTest`, and
  ```zig
  pub fn scrollBy(self: *Layout, delta: i32) void;                         // clamp to [0, overflow]
  pub fn dragUpdate(drag: *Drag, layout: *const Layout, m: Metrics, x: i32) ?struct { from: usize, to: usize }; // activates after drag_threshold; target = slot whose centre range holds x - grab_dx + w/2
  pub fn dragOffset(drag: *const Drag, layout: *const Layout, x: i32) i32;   // painter x for the dragged tab
  ```
  Rules: caption buttons (titlebar mode only) at the right edge, close rightmost; `available = width - tab_pad - new_tab_w - min_drag_w - buttons`; tab width `clamp(available / count, tab_min_w, tab_max_w)`; overflow → `tab_min_w`, `scroll` keeps the active tab inside `clip`; `new_tab` follows the last tab (or sits at the clip end on overflow); `caption` = the gap between `new_tab` and the buttons; with `show_tabs == false` in titlebar mode: no tab rects, `title` = `[tab_pad, new_tab.x)`, `new_tab` just left of the buttons. `tab_close` is the right `close_w` of a tab and only hit for the active or hovered tab, and only when the tab is ≥ 2×`close_w` wide. `resize_top` when not maximized and `y < resize_band` (titlebar mode).
- [ ] **Step 1: Failing tests**
  ```zig
  test "win32 tabstrip: metrics scale with dpi" { // 144 dpi → height 60, caption_btn_w 69 }
  test "win32 tabstrip: three tabs in 1200 px titlebar" { // widths 240, tab 0 x 10, buttons [1062..1200], caption between new_tab and 1062 }
  test "win32 tabstrip: overflow keeps active visible" { // 30 tabs, width 800, active 29 → tabs[29] inside clip; scrollBy(-10000) → scroll 0 }
  test "win32 tabstrip: hit test parts" { // caption, each button, tab body vs tab_close (active only), new_tab, resize_top only when !maximized }
  test "win32 tabstrip: narrow tab has no close hit" {}
  test "win32 tabstrip: drag reorder after threshold" { // begin on tab 0, move 3 px → null; move past tab 1 centre → {0,1}; further → {1,2} }
  test "win32 tabstrip: hidden mode has zero height" {}
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 tabstrip"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): tab strip layout, hit testing and drag reorder model"`

### Task 11: IPC ops on the UI thread, pipe claim in `App.init`, test oracle

**Files:**
- Modify (replace stub): `src/apprt/win32/ipc/ops.zig`
- Modify: `src/apprt/win32/App.zig` (`init`: right after the message-only window exists, `Server.claim(instance.pipeNameFor(config.class))` then `start(msg_hwnd)` — before any window, so a second launch 50 ms later already finds the pipe and queues in it (pre-flight 5); `AddressInUse` → `server = null`, log info (Task 20 adds forwarding and the non-owner lifecycle); `msgWndProc` handles `WM_GHOSTTY_IPC`; `terminate` stops the server first; at startup `testOpsEnabled()` is cached and `GHOSTTY_WIN32_TEST_IPC` is removed from the process environment so shells and nested launches never inherit test ops (pre-flight 7))
- Create: `test/windows/lib/GhosttyIpc.psm1`, `test/windows/e2e/ipc-state.ps1`

**Interfaces:**
- Consumes: Tasks 5, 6a, 6b, 8; `input.Binding.Action.parse`, `CoreSurface.performBindingAction`, `CoreApp.findSurfaceByID`.
- Produces:
  ```zig
  pub fn handle(app: *App, alloc: Allocator, request: []const u8) []u8;  // never fails: errors become a response; expired requests → code 1 "expired", no side effect
  pub fn testOpsEnabled() bool;   // env GHOSTTY_WIN32_TEST_IPC == "1" at process start (cached before the variable is removed)
  // App fields: server: ?*ipc.Server = null, pub fn serving(self) bool
  ```
  Op semantics: `new-window` → `Overrides.parse(args)` → `Window.create(app, .{ .overrides })`, show, `SetForegroundWindow`; `new-tab` → `core_surface` id (decimal string, `"0"` = focused) → that surface's window `addTab(.{ .parent, .overrides })`, none → new window; `toggle-quick-terminal` → code 1 `quick terminal is not available yet`. A request whose args contain a command (`-e`, `--command=`) is refused with code 1 even if a client sent it (defence in depth for pre-flight 2). Test ops (code 2 `unknown op` unless `testOpsEnabled`): `action` → surface (`0` = `core_app.focusedSurface() orelse app.last_active.activeTab().focusedSurface()`), `performBindingAction(parse(action))`, data `{"performed":bool}`; `dpi` → `window.applyDpi(dpi, null)` (the window's `dpi` field is the single source, so the simulation and a real `WM_DPICHANGED` take the same path; pre-flight 16); `color-scheme` → `theme.schemeChanged(app, …)`; `state` → data:
  ```json
  {"class":"…","serving":true,"elevated":false,"windows":[{"id":1,"hwnd":"0x…","title":"…","dpi":96,"maximized":false,"minimized":false,
    "fullscreen":false,"topmost":false,"decorations":"server","client":[l,t,r,b],"window":[l,t,r,b],"cell":[w,h],
    "progress":null,"active_tab":0,
    "strip":{"mode":"hidden","bounds":[…],"tabs":[[…]],"new_tab":null,"minimize":null,"maximize":null,"close":null,"caption":[…]},
    "tabs":[{"id":1,"title":"…","zoomed":false,"bell":false,
      "surfaces":[{"id":1,"core_id":"…","hwnd":"0x…","rect":[l,t,r,b],"visible":true,"focused":true,"title":"…",
                   "scale":1.0,"scrollbar":{"total":0,"offset":0,"len":0}}]}]}]}
  ```
  (rects in window client coordinates; `client`/`window` in screen coordinates; `core_id` as a string because it is a u64; `scale` from the surface's own content scale, not recomputed from `dpi`).
  `GhosttyIpc.psm1`: `Get-GhosttyPipeName -Class [-Elevated]` (SID from `WindowsIdentity`, session from `Get-Process -Id $PID`), `Invoke-GhosttyIpc -Class -Request <hashtable> [-TimeoutMs 5000]` → parsed response (sets `deadline_ms`), `Get-GhosttyState -Class`, `Invoke-GhosttyAction -Class -Action <s> [-Surface <id>]`, `Wait-GhosttyState -Class -Predicate {…} [-TimeoutSec]`. Mouse helpers are not here: Task 17 creates `test/windows/lib/MouseInput.psm1` with the first scenario that clicks (pre-flight 15).
- [ ] **Step 1: Failing test** `"win32 ipc ops: unknown and test ops are refused without the env flag"` (`pub var test_ops_override: ?bool = null` in ops.zig, set to false by the test; `handle` with an `undefined` app pointer must not touch it for these requests → `state` and `action` answer code 2; malformed JSON → code 2; `v:2` → code 3; an expired `new-window` → code 1; `new-window` with `{"-e","x"}` → code 1).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 ipc ops"` → FAIL.
- [ ] **Step 3: Implement** ops, pipe claim, the PowerShell module, scenario `ipc-state` (`milestone=M2 order=200`): start Ghostty, `Get-GhosttyState` → 1 window, 1 tab, 1 surface whose `hwnd` equals the child of `$G.Hwnd`, `serving = true`; `Invoke-GhosttyAction 'text:echo ipc-ok> %TEMP%\gt-ipc.txt\r'` → file contains `ipc-ok`; `text:set GHOSTTY_WIN32_TEST_IPC > %TEMP%\gt-env.txt\r` → the variable is not defined in the shell; a second start with `Start-E2eGhostty -NoTestIpc` → `state` answers code 2.
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build -j2`; `E2E -Only ipc-state,startup` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): IPC ops on the UI thread, pipe claimed at startup, test-state oracle"`

### Task 12: Chrome spike — Mica, custom caption, child swap chains, re-parenting, D2D strip (risk R9)

**Files:** Create `test/windows/chrome-spike/build.zig`, `test/windows/chrome-spike/main.zig`, `test/windows/chrome-spike/run.ps1`.

**Interfaces:**
- Consumes: Task 7 bindings, `pkg/win32` d3d11/dxgi, Task 4 Harness (lock, `Assert-FreeRam`).
- Produces: decisions (written into the commit body and the report; the lead records them as SPEC §18.9): (1) painter backend `dc` (software `ID2D1DCRenderTarget` bound to a `BeginBufferedPaint` DC, premultiplied alpha, grayscale text AA) or fallback `opaque` (no Mica; R9 fallback) — the `hwnd` variant is dropped: an `ID2D1HwndRenderTarget` on a `WS_CLIPCHILDREN` top-level gives no per-pixel alpha over the extended frame, so it cannot win (pre-flight 10); (2) whether `SetParent` keeps a presenting flip-model swap chain working (decides whether Task 30 is the mechanism or a defensive fallback). The spike exe: top-level `WS_OVERLAPPEDWINDOW|WS_CLIPCHILDREN`, `WM_NCCALCSIZE` removing the caption (keeping side/bottom frames), `DwmExtendFrameIntoClientArea(top = 40)`, `DWMWA_SYSTEMBACKDROP_TYPE = DWMSBT_MAINWINDOW`, dark mode; a child HWND below the strip with a FLIP_DISCARD swap chain cleared to `#102030` and presented at 60 Hz for 8 s; strip painted by `--variant=none|dc` (transparent clear, one rounded tab rect `#102030`, DWrite text "Spike Tab", caption glyphs U+E921/U+E922/U+E8BB in Segoe Fluent Icons); `WM_NCHITTEST` returns `HTMAXBUTTON` over the max glyph; `--reparent` creates a second top-level after 3 s and `SetParent`s the presenting child into it (the swap chain is NOT recreated), clear colour switches to `#203010`.
- [ ] **Step 1:** Build `LOCK ZIG build -j2 --build-file test/windows/chrome-spike/build.zig`.
- [ ] **Step 2:** `run.ps1` (Harness, desktop lock, SKIP when not interactive) runs each variant: foreground the window, `CopyFromScreen` of the window rect to `%TEMP%\chrome-spike-<variant>.png`, sample: strip background pixel ≠ `#000000` and ≠ the child colour (backdrop visible), child pixel `#102030` ±2, text pixels present; `PrivateMemorySize64` after 5 s per variant (`none` is the baseline); hover the max button 1 s and capture again (snap flyout visible = manual look, recorded). Extra checks (pre-flight 10): (a) `--variant=none --no-buttons`: the top-right 3×46 px caption area shows no DWM-drawn "ghost" caption buttons (pixels equal the strip background ±6 with and without hover); (b) maximized under Mica: the window rect stays inside the monitor (`MonitorFromWindow` rect expanded by the frame inset) and the client top is on-screen; (c) `--reparent`: the child in the second window shows `#203010` ±2 within 1 s and keeps presenting (two captures 500 ms apart both match), no DXGI error in the spike log.
- [ ] **Step 3: Decide** — `dc` if its strip shows the backdrop and text correctly, (a) and (b) hold, and its RAM delta ≤ 3 MB; else `opaque`. Re-parent: (c) holds → Task 30 keeps only the generation bump as a defensive path (no recreation unless a present fails with `DXGI_ERROR_INVALID_CALL`/`E_ACCESSDENIED`); (c) fails → Task 30 as written, with the failure mode recorded. Attach the PNGs and the RAM table to the report.
- [ ] **Step 4: Commit** `git commit -m "test(windows): chrome spike for Mica, caption, re-parenting and Direct2D strip painting"` (body: variant table + decisions)

### Task 13: Tabs

**Files:**
- Modify: `src/apprt/win32/Window.zig` (`addTab` honours `window-new-tab-position`; `moveTab`; `showTabs` from `window-show-tab-bar`; title refresh on tab/surface title changes; `refreshTitle` passes the title through `bell.decorateTitle` so Task 26 never edits `Window.zig` — pre-flight 3d), `src/apprt/win32/actions/tab_actions.zig`, `src/apprt/win32/actions/window_actions.zig` (`set_window_title`)
- Create: `test/windows/e2e/tabs-basic.ps1`, `test/windows/e2e/tabs-keys.ps1`

**Interfaces:**
- Consumes: Tasks 6a/6b model and close flow, Task 11 oracle, Task 2 `bell.decorateTitle` stub.
- Known gap recorded, not fixed (pre-flight 27): new tabs and splits do not inherit the cwd from Git Bash, because OSC 7 reports `/c/…` and `Exec.zig`'s access check rejects it; OSC 7 translation stays in M5 (SPEC §17) and the M2 changelog states the gap.
- Produces:
  ```zig
  pub fn moveTab(self: *Window, from: usize, to: usize) void;   // reorder, keep the same tab active, Chrome.invalidate
  pub fn newTabIndex(position: configpkg.Config.WindowNewTabPosition, active: usize, count: usize) usize; // pure: current → active+1, end → count
  pub fn showTabsFor(setting: configpkg.Config.WindowShowTabBar, count: usize) bool; // pure: always → true, never → false, auto → count > 1
  pub fn gotoIndex(target: apprt.action.GotoTab, current: usize, count: usize) ?usize; // pure, GTK window.zig selectTab semantics; null when unchanged
  pub fn moveIndex(amount: isize, current: usize, count: usize) ?usize;  // pure, GTK moveTab (wraps), null when count == 1
  ```
  Handlers: `new_tab` (surface target → its window, parent = target; app target → `app.last_active` else a new window), `close_tab` `this|other|right` (posts `WM_GHOSTTY_CLOSE_TAB` with mode + tab id; the handler confirms once with `CloseKind.tab` if any affected tab `needsConfirmClose`), `goto_tab`, `move_tab`, `set_tab_title` (tab override; empty clears), `set_title` (surface title; refresh tab/window titles when it is the active tab's focused surface), `set_window_title` (window override), `copy_title_to_clipboard` (`clipboard.write` of the surface title; false when none), `pwd` (stored on the surface for `window-subtitle`; returns true). Return `false` whenever nothing changed (performable bindings then reach the shell).
- [ ] **Step 1: Failing tests** `"win32 window: new tab index"`, `"win32 window: show tabs setting"`, `"win32 window: goto tab index matches GTK"` (prev wraps 0→count-1; next wraps; last; n=0 → null; n > count → last; same → null), `"win32 window: move tab wraps"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 window"` → FAIL.
- [ ] **Step 3: Implement**; scenarios (`milestone=M2`): `tabs-basic` (order 210; via `Invoke-GhosttyAction`: `new_tab` ×2 → 3 tabs active 2; `goto_tab:1` → active 0, only tab 0's surface `visible`; `move_tab:1` → tab order ids swapped; `text:title tab-A\r` in tab 0 → tab 0 title `tab-A` and window caption (`GetWindowText`) `tab-A`; `set_tab_title:fixed` → title `fixed`; `close_tab:right` → 1 tab left; `close_tab:this` on the last tab → process exits ≤ 3 s), `tabs-keys` (order 220; real keys `ctrl+shift+t`, `ctrl+tab`, `ctrl+shift+w` with cmd → tab counts 2, active 0/1, 1).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only tabs-basic,tabs-keys` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): tabs — new/close/goto/move, titles and tab-bar visibility"`

### Task 14: Splits

**Files:**
- Modify: `src/apprt/win32/Tab.zig` (`layout` through `SplitLayout` with `DeferWindowPos`, hidden leaves `SWP_HIDEWINDOW` + occlusion, cached `split_layout`), `src/apprt/win32/actions/split_actions.zig`, `test/windows/measure-ram.ps1` (scenarios `tabs`, `splits`, `zero-windows`, driven by `Invoke-GhosttyAction`, no keyboard input — pre-flight 11), `docs/windows/ram-baseline.csv`
- Create: `test/windows/e2e/splits-basic.ps1`, `test/windows/e2e/split-close.ps1`, `test/windows/e2e/split-many.ps1`

**Interfaces:**
- Consumes: Tasks 6a, 6b, 9, 11; Task 36 tracer (`GHOSTTY_LATENCY_TRACE`) and Task 37 fixes for the pacing check.
- Produces:
  ```zig
  // Tab.zig
  split_layout: ?SplitLayout.Layout(Surface.Tree) = null,
  pub fn split(self: *Tab, at: *Surface, direction: Surface.Tree.Split.Direction) !*Surface; // new surface (context .split, parent at), tree.split(…, 0.5, …), focus it
  pub fn handleOf(self: *const Tab, s: *const Surface) ?Surface.Tree.Node.Handle;
  ```
  Handlers: `new_split` (right/down/left/up), `goto_split` (`previous/next` → `previous_wrapped/next_wrapped`, directions → `.spatial`, as GTK `split_tree.zig`; false when the result is the same surface), `resize_split` (`SplitLayout.resizeRatio` over the container bounds → `tree.resize`), `equalize_splits` (`tree.equalize`), `toggle_split_zoom` (`tree.zoom(handle)` / `zoom(null)`; false with a single leaf). Removal keeps Task 6a's `focusAfterRemove`; zoom of a removed leaf is cleared.
- [ ] **Step 1: Failing test** `"win32 tab: split layout hides zoomed-out leaves"` (pure helper `visibilityChanges(old: []const Leaf, new: []const Leaf) []struct{ view, visible }` that drives the occlusion calls; zoom on → others false; off → true).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 tab"` → FAIL.
- [ ] **Step 3: Implement**; scenarios (`milestone=M2`): `splits-basic` (order 230: `new_split:right`, `new_split:down` → 3 surfaces, rects tile the content area with gaps of `gapPx(dpi)`; `goto_split:left` → focused = first; `resize_split:right,100` → left width +100 ±2; `equalize_splits` → left ≈ half; `toggle_split_zoom` → one visible surface with the full content rect, then back), `split-close` (order 240: `text:exit\r` in the focused split of three → 2 surfaces, focus on a live one, no orphan `cmd.exe` of the closed one after 3 s), `split-many` (order 250, header `surfaces=16`: 15 × `new_split` alternating right/down → 16 surfaces, every visible rect w,h ≥ 0, no overlap, no `error` lines in `ghostty.log`, window still answers `WM_NULL` ≤ 2 s; pacing (pre-flight 22): 4 panes stream `_stream.ps1` output while 20 keys are typed into a fifth pane with the tracer on → keypress→present p95 ≤ 33 ms and output→present of the typed pane p95 ≤ 20 ms (Task 36 scenario c2) on ReleaseFast (recorded only on Debug); close (pre-flight 13): `close_window` with 4 panes still streaming → the top-level is invisible (`IsWindowVisible` false) within 300 ms, and a second Ghostty window of the same process (opened through the `new-window` IPC op before the close; the `new_window` action arrives with Task 21) answers `SendMessageTimeout(WM_NULL)` within 100 ms throughout the teardown).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only splits-basic,split-close,split-many` → PASS.
- [ ] **Step 5: RAM probe** (pre-flight 11): `LOCK ZIG build -j2 -Doptimize=ReleaseFast --prefix zig-out-rf`; `measure-ram.ps1 -Scenario one-surface,splits,zero-windows` on the RF exe (`tabs` is written here and first run at gate G1, because Task 13 lands in the same wave). Rows appended to `docs/windows/ram-baseline.csv`. `zero-windows` = one window opened then closed with the Windows default `quit-after-last-window-closed = false` (process resident in the tray from Task 28 on; before Task 28 the row records `n/a`).
- [ ] **Step 6: Commit** `git commit -m "feat(win32): splits over the core SplitTree — create, close, goto, resize, equalize, zoom; RAM probe rows"`

**Gate G1 (lead, after W6, before W7 starts):** run `measure-ram.ps1 -Scenario one-surface,tabs,splits` on ReleaseFast and record the rows. Decision recorded in the ledger: per tab/split ≤ +10 MB → continue as planned. Over → the lead adds tasks before Task 35 from the named levers: (1) an occluded surface (hidden tab, zoomed-out split, minimized window) releases its swap chain or `ResizeBuffers` to 8×8 on occlusion and restores on show (renderer `D3D11.zig`, after Task 30 in the chain); (2) one shared glyph atlas texture per font set across surfaces (renderer, M3-sized: only if (1) is not enough); (3) renderer threads: a surface's renderer timer thread stays idle when occluded (already true upstream, verify). Exit item 5 stays a hard gate; if no lever brings the numbers within target, the lead takes the numbers to the owner before Task 35 instead of shipping DONE_WITH_CONCERNS silently.

### Task 15: Theme, system colour scheme, config reload, open_config

**Files:**
- Modify (replace stubs): `src/apprt/win32/theme.zig`, `src/apprt/win32/actions/app_actions.zig` (`reload_config`, `config_change`, `open_config`, `color_change`)
- Modify (append): `pkg/win32/uxtheme.zig` (`SetWindowTheme`), `pkg/win32/shell32.zig` (`ShellExecuteW`, `SE_ERR_NOASSOC`)
- Modify (core touch point, pre-flight 22): `src/config/command.zig` (`formatEntry` writes through the formatter's writer instead of a 4096-byte fixed buffer, so `reload_config` and `+show-config` handle a long `direct:` command; test `"config command: formatEntry with a 10000-byte direct command"`)
- Create: `test/windows/e2e/theme.ps1`, `test/windows/e2e/config-reload.ps1`

**Interfaces:**
- Consumes: Task 6b hooks; Task 11 `color-scheme` op; GTK `application.zig reloadConfig` and `openConfig` (path helper) for semantics.
- Produces:
  ```zig
  pub fn compute(config: *const configpkg.Config, system_dark: bool, active: bool) Palette;  // pure
  pub fn isDark(config: *const configpkg.Config, system_dark: bool) bool;                    // window-theme: light/dark explicit; auto/system → system; ghostty → luminance(background) < 0.5
  var system_dark: ?bool = null;                    // module state, UI thread only; null until first read
  pub fn palette(window: *const Window) Palette;    // compute(app.config, system_dark, window is foreground)
  pub fn applyToWindow(window: *Window) void;       // first call: read util.systemUsesDarkTheme into system_dark and call core_app.colorSchemeEvent once;
                                                    // DWMWA_USE_IMMERSIVE_DARK_MODE = isDark; SetWindowTheme(surface hwnds, "DarkMode_Explorer"|null) for scrollbars; Chrome.invalidate
  pub fn schemeChanged(app: *App, scheme: apprt.ColorScheme) void; // system_dark; core_app.colorSchemeEvent; every surface colorSchemeCallback; applyToWindow all
  pub fn settingChanged(app: *App, lparam: LPARAM) void; // "ImmersiveColorSet" → re-read AppsUseLightTheme → schemeChanged; SPI_SETHIGHCONTRAST/"WindowsThemeElement" → re-read high contrast → applyToWindow all
  // handle: WM_SETTINGCHANGE → settingChanged (one broadcast reaches every top-level; only the first per message tick acts); WM_ACTIVATE → Chrome.invalidate
  // With 0 windows the message-only window gets no broadcast: Task 28's tray window forwards its WM_SETTINGCHANGE to settingChanged (pre-flight 19).
  pub fn highContrast() bool;                       // SPI_GETHIGHCONTRAST & HCF_HIGHCONTRASTON (cached, refreshed by settingChanged)
  // compute(): high contrast → mica = false and the palette from GetSysColor(COLOR_WINDOW/COLOR_WINDOWTEXT/COLOR_HIGHLIGHT/COLOR_HIGHLIGHTTEXT)
  ```
  This task does not edit `App.zig` (not its wave).
  Palette values: dark → `text #FFFFFF`, `text_inactive #9E9E9E`, `tab_hover_bg #FFFFFF a=0x10`, `button_hover_bg #FFFFFF a=0x15`, `button_pressed_bg #FFFFFF a=0x0B`, `strip_bg #202020`, `divider #3C3C3C`; light → `text #000000 a=0xE4`, `text_inactive #5C5C5C`, `tab_hover_bg #000000 a=0x0A`, `button_hover_bg #000000 a=0x09`, `button_pressed_bg #000000 a=0x06`, `strip_bg #F3F3F3`, `divider #C8C8C8`; `tab_active_bg` = config `background`; `split-divider-color` overrides `divider`; `mica = (Task 12 decision ≠ opaque) and window-theme ≠ ghostty`, `strip_bg.a = 0` when mica; `window-theme = ghostty` → `strip_bg = window-titlebar-background orelse background`, `text = window-titlebar-foreground orelse foreground`.
  `reload_config` soft → `core_app.updateConfig(app, &app.config)` (app target) or `core.updateConfig` (surface target); hard → `Config.load`, `updateConfig`, then replace `app.config` (old freed after the call). `config_change` (app target) → `applyToWindow` + `layout` for every window. `open_config` → the GTK path helper, `ShellExecuteW("open")`, on `SE_ERR_NOASSOC` (31) `notepad.exe <path>`. `color_change` → `Chrome.invalidate` for the surface's window (window-theme ghostty follows OSC 11).
- [ ] **Step 1: Failing tests** `"win32 theme: dark and light palettes"`, `"win32 theme: ghostty theme follows background luminance"` (bg `#FAFAFA` → light, `#101010` → dark), `"win32 theme: titlebar colours only with window-theme ghostty"`, `"win32 theme: mica clears strip alpha"`, `"win32 theme: high contrast disables mica"` (pure `compute` with an injected high-contrast flag and system colours).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 theme"` → FAIL.
- [ ] **Step 3: Implement**; scenarios: `theme` (order 260: two theme files in the sandbox config dir, `gt-light` with `background = #f0f0f0` and `gt-dark` with `background = #101010`, config `theme = light:<abs path gt-light>,dark:<abs path gt-dark>`; `color-scheme` op light → dump background = light value; dark → dark value; `DwmGetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE)` matches), `config-reload` (order 270: edit the sandbox config `background = #203040`, `Invoke-GhosttyAction reload_config` → dump pixel `#203040`).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only theme,config-reload` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): window theme, system colour scheme, config reload and open_config"`

### Task 16: Split divider drag, divider paint, focus-follows-mouse

**Files:**
- Modify: `src/apprt/win32/Tab.zig` (container `WM_ERASEBKGND`/`WM_PAINT` fill = `theme.palette(window).divider`; `WM_SETCURSOR` size cursors over dividers; `WM_LBUTTONDOWN/MOUSEMOVE/LBUTTONUP` drag with capture → `tree.resizeInPlace` + `layout` at most every 16 ms, final layout on release, focus back to the focused surface), `src/apprt/win32/mouse.zig` (`focus-follows-mouse`: `WM_MOUSEMOVE` over an unfocused surface of the foreground window → `SetFocus`; reuse `Surface.class_name`; `refreshCursor` handles the captured surface — M1 Task 24 minors)
- Create: `test/windows/e2e/split-divider-drag.ps1` (uses `MouseInput.psm1` from Tasks 17/19; does not edit it)

**Interfaces:**
- Consumes: Tasks 9, 14; `Send-MouseDrag` (Task 19); `messages` timer id `GhosttyTab 1` for the throttled relayout.
- Produces: `pub fn dragMinPx(cell: apprt.action.CellSize) i32` in Tab.zig (= 2 cells of the axis, min 16 px).
- [ ] **Step 1: Failing test** `"win32 tab: drag minimum is two cells"` (`{w 9, h 18}` horizontal → 18, vertical → 36; zero cell → 16).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 tab"` → FAIL.
- [ ] **Step 3: Implement**; scenario `split-divider-drag` (order 280: two splits; `Send-MouseDrag` from the divider centre +150 px → left width +150 ±3; drag to x=1 → left width ≥ `dragMinPx`; config `focus-follows-mouse = true`: move the cursor over the right surface → state `focused` moves without a click).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only split-divider-drag,splits-basic` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): split divider drag and paint, focus-follows-mouse"`

### Task 17: Custom frame — caption removal, hit testing, caption buttons, snap layouts, Mica

**Files:**
- Modify (replace stubs): `src/apprt/win32/frame.zig`
- Create: `test/windows/e2e/frame-hittest.ps1`, `test/windows/lib/MouseInput.psm1` (`Send-MouseClick -Hwnd -X -Y [-Button left|middle|right] [-Double]`, client coordinates of `-Hwnd`, `SendInput` absolute; only inside a scenario — moved out of Task 11, pre-flight 15)

**Interfaces:**
- Consumes: Task 10 (`hitTest`), Task 12 decisions (Mica or opaque; no ghost buttons; maximized insets), Task 15 palette (`mica`), Task 6a (`window.dpi`).
- Also produces the real `nonClientSize(window)` (pre-flight 9): `frameInsets(dpi, maximized, decorations)` widths + strip height when the strip sits inside the client area (`client` decorations), or the `AdjustWindowRectExForDpi` value for `server`; every size path (initial_size, size_limit / `WM_GETMINMAXINFO`, `resize_window`, `reset_window_size`) already goes through it since Task 6a.
- Frame polish (pre-flight 25): in the opaque fallback extend the frame by 1 px at the top (`MARGINS.cyTopHeight = 1`) so restored windows keep the DWM top border; `frame.hover` (non-client) and `window.strip_input.hover` (client) are mutually exclusive — each update clears the other and invalidates.
- Produces:
  ```zig
  pub fn decorationsFor(setting: configpkg.Config.WindowDecoration) Decorations;   // auto|client → client, server, none
  pub fn ncHitCode(part: TabStrip.Part, x: i32, width: i32, resize_band: i32) u32; // caption→HTCAPTION, minimize→HTMINBUTTON, maximize→HTMAXBUTTON, close→HTCLOSE, resize_top→HTTOPLEFT|HTTOP|HTTOPRIGHT by x, others→HTCLIENT
  pub fn frameInsets(dpi: u32, maximized: bool, decorations: Decorations) struct { left: i32, top: i32, right: i32, bottom: i32 }; // client: restored = {frame, 0, frame, frame}; maximized = frame on all four (SM_CXFRAME + SM_CXPADDEDBORDER at dpi); none = 0; fullscreen handled by placement
  ```
  `handle`: `WM_NCCALCSIZE` (wparam TRUE, decorations client/none) applies `frameInsets` to `rgrc[0]` and returns 0; `WM_NCHITTEST` → `DefWindowProcW` for side/bottom borders, then strip `hitTest` → `ncHitCode`; `WM_NCMOUSEMOVE/WM_NCMOUSELEAVE` hover with `TrackMouseEvent(TME_NONCLIENT|TME_LEAVE)` → `frame.hover`, `Chrome.invalidate`; `WM_NCLBUTTONDOWN` on min/max/close → `pressed`, return 0 (DefWindowProc must not draw classic buttons); `WM_NCLBUTTONUP` on the pressed part → `WM_SYSCOMMAND SC_MINIMIZE | SC_MAXIMIZE/SC_RESTORE | SC_CLOSE`; everything else (caption drag, double-click maximize, right-click system menu) → `DefWindowProcW`; `WM_NCACTIVATE` → invalidate. `apply`: `frame.decorations = decorationsFor(config)`, `DwmExtendFrameIntoClientArea(top = strip height when palette.mica else 0)`, `DWMWA_SYSTEMBACKDROP_TYPE = mica ? DWMSBT_MAINWINDOW : DWMSBT_NONE`, `SetWindowPos(SWP_FRAMECHANGED)`, `window.layout()`. `stripMode`: fullscreen → hidden; client → titlebar; none → tabs_only if `showTabs()` else hidden; server → tabs_only if `showTabs()` else hidden. **Task 12 outcome (SPEC §18.9, lead ruling):** with `client` decorations the top-level is created WITHOUT `WS_SYSMENU` (otherwise DWM paints ghost caption buttons over the strip); `frame` shows the system menu itself on Alt+Space and caption right-click (`GetSystemMenu` + `TrackPopupMenuEx(TPM_RETURNCMD)` → `WM_SYSCOMMAND`) and swallows a lone-Alt `SC_KEYMENU`; `server` decorations keep `WS_SYSMENU`. If any acceptance item in Step 3 cannot be met without `WS_SYSMENU`, fall back to the opaque painter with `WS_SYSMENU` and report it.
- [ ] **Step 1: Failing tests** `"win32 frame: decorations mapping"`, `"win32 frame: hit codes incl. top corners"`, `"win32 frame: insets restored vs maximized at 96 and 144 dpi"` (values from `GetSystemMetricsForDpi`, asserted structurally: maximized top == side inset > 0, restored top == 0).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 frame"` → FAIL.
- [ ] **Step 3: Implement**; scenario `frame-hittest` (order 290: `SendMessage(WM_NCHITTEST)` at screen points from the state strip rects → caption 2, max 9, min 8, close 20, tab 1, top edge 12 when restored; `toggle_maximize` via action → window rect ⊆ monitor work area expanded by the frame inset and the client rect fully on the monitor; double-click caption point (`Send-MouseClick -Double`) → maximized toggles; Alt+Space → a `#32768` menu window appears, Esc closes it; WS_SYSMENU-removal acceptance (SPEC §18.9): caption right-click menu, Alt+F4 closes, Win+Up/Down maximize/restore, a lone Alt tap does not freeze the UI and Alt+x reaches the terminal, the inactive caption repaints, taskbar-button context menu shows Close; snap-flyout layout selection and drag-to-top snap recorded by hand in the report).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only frame-hittest` → PASS; screenshot of the titlebar attached.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): custom DWM frame with own caption buttons, snap layouts hit testing and Mica"`

### Task 18: Chrome painter — tab strip and caption buttons with Direct2D/DirectWrite

**Files:**
- Modify (replace stubs): `src/apprt/win32/Chrome.zig`
- Modify: `src/apprt/win32/App.zig` (`terminate` calls `Chrome.deinitShared()`; `BufferedPaintInit/UnInit` around the loop)
- Modify (append): `pkg/win32/uxtheme.zig` (`BufferedPaintInit BufferedPaintUnInit BeginBufferedPaint EndBufferedPaint BufferedPaintClear`, `BP_PAINTPARAMS`, `BPBF_TOPDOWNDIB`)
- No e2e here: until Task 17 lands in the same wave `frame.stripMode` is the `.hidden` stub, so there is no strip on screen; the `chrome-paint` scenario moves to Task 19 (pre-flight 3b).

**Interfaces:**
- Consumes: Tasks 7, 10, 12 (backend), 15 (palette).
- Produces:
  ```zig
  pub const Shared = struct { d2d: *ID2D1Factory, dwrite: *IDWriteFactory, target: *ID2D1DCRenderTarget (dc backend), formats: per-dpi cache { title, icons } };
  pub fn shared() !*Shared;            // lazy, UI thread
  pub fn paint(window: *Window, hdc: HDC, dirty: geom.Rect) void;  // never fails visibly: on error FillRect with palette.strip_bg and log once
  pub fn drawCaption(target, palette, layout, frame_state)  // internal
  pub fn paintTabChip(hdc: HDC, size: geom.Rect, title: []const u8, palette: theme.Palette, dpi: u32) void; // one active-style tab into a premultiplied DIB (drag ghost, Task 31)
  // drop marker: when window.strip_input.drop_index is set, a 2-px bar in palette.text at that insertion slot
  ```
  Drawing: clear strip to `palette.strip_bg` (transparent with Mica); inactive tabs text `text_inactive`, hovered tab fill `tab_hover_bg`; active tab rounded-top rect (radius `geom.scale(6)`) filled `tab_active_bg` merging into the content; titles DWrite `Segoe UI Variable Text` (fallback `Segoe UI`) 12 DIP, ellipsis trimming, grayscale AA over transparent areas; bell glyph U+EA8F before the title when `tab.bellRinging()` and `bell-features.title`; close glyph U+E8BB on active/hovered tabs; new-tab U+E710; caption buttons min U+E921, max U+E922 / restore U+E923 (`IsZoomed`), close U+E8BB in `Segoe Fluent Icons` (fallback `Segoe MDL2 Assets`) 10 DIP; hover/pressed fills from `frame.hover/pressed`, close hover `close_hover_bg` + `close_hover_text`; dragged tab drawn at `TabStrip.dragOffset`; `title` rect (tabs hidden) shows `window.title_override orelse active tab title`. Format cache keyed by DPI; brushes created per paint (one solid brush, `SetColor`).
- [ ] **Step 1: Failing test** `"win32 chrome: paints a strip into a DIB"` (headless: a fake 600×40 `TabStrip.Layout` with 2 tabs, dark palette with mica, paint into a 32bpp DIB through the same code path as `paint` (`paintInto(hdc, size, inputs)` internal fn): active tab pixel ≈ `tab_active_bg`, a pixel left of tab 0 has alpha 0, close button area of the active tab contains non-transparent pixels).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 chrome"` → FAIL.
- [ ] **Step 3: Implement** (the scenario text formerly here now lives in Task 19).
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build -j2`; `E2E -Only startup,render` → PASS (no strip visible yet; nothing regressed).
- [ ] **Step 5: Commit** `git commit -m "feat(win32): Direct2D tab strip and caption button painting"`

### Task 19: Strip mouse input and inline title editing

**Files:**
- Modify (replace stubs): `src/apprt/win32/strip_input.zig`, `src/apprt/win32/title_edit.zig`, `src/apprt/win32/actions/window_actions.zig` (`prompt_title` → `title_edit.prompt`)
- Modify (append): `pkg/win32/comctl32.zig` (`SetWindowSubclass DefSubclassProc RemoveWindowSubclass`, `SUBCLASSPROC`), `test/windows/lib/MouseInput.psm1` (`Send-MouseDown`, `Send-MouseMove -Steps`, `Send-MouseUp` primitives — a scenario can check state mid-drag, pre-flight 20 — and `Send-MouseDrag -Hwnd -X -Y (-ToX -ToY | -ToScreenX -ToScreenY) [-Steps 1] [-HoldMs 0]` built on them)
- Create: `test/windows/e2e/tab-strip-mouse.ps1`, `test/windows/e2e/tab-rename.ps1`, `test/windows/e2e/chrome-paint.ps1` (moved from Task 18)

**Interfaces:**
- Consumes: Tasks 10, 13, 17, 18.
- `WM_GHOSTTY_TITLE_EDIT_DONE` is posted to the top-level and consumed by `strip_input.handle` (it runs in the Task 6b hook chain), so `Window.zig` is not edited (pre-flight 3e).
- Deferred to M3 and listed in Task 3's deferred notes / the changelog (pre-flight 29): the tab context menu (close / close others / rename / move to new window) and the full-title tooltip on trimmed tabs.
- Produces:
  ```zig
  // strip_input.handle: WM_LBUTTONDOWN (tab → selectTab + begin drag; tab_close → post WM_GHOSTTY_CLOSE_TAB this; new_tab → addTab(parent = active surface)),
  // WM_MOUSEMOVE (hover + TrackMouseEvent leave; dragUpdate(drag, layout, metrics, x) → window.moveTab), WM_LBUTTONUP (end drag, focus active surface),
  // WM_MBUTTONUP on a tab → close that tab, WM_LBUTTONDBLCLK on a tab → title_edit.begin(.tab), WM_MOUSEWHEEL over the strip → strip.scrollBy,
  // WM_MOUSELEAVE → hover nowhere; every handled message ends with the active surface focused
  // title_edit.zig
  pub const Kind = enum { surface, tab, window };
  pub fn begin(window: *Window, kind: Kind, rect: geom.Rect, initial: []const u8) void; // EDIT child of the top-level (ES_AUTOHSCROLL, Segoe UI at dpi), subclassed: Enter commits, Esc / focus loss cancels; commit posts WM_GHOSTTY_TITLE_EDIT_DONE
  pub fn prompt(app: *App, target: apprt.Target, value: apprt.action.PromptTitle) bool;  // tab → over the tab rect; surface/window → over strip.title or caption rect
  // commit: tab → tab.title_override (empty clears), surface → surface title override, window → window.title_override; refreshTitle + invalidate
  ```
- [ ] **Step 1: Failing test** `"win32 title edit: commit text normalisation"` (pure `normalize(text) ?[]const u8`: trims, CR/LF removed, empty → null (clears)).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 title edit"` → FAIL.
- [ ] **Step 3: Implement**; scenarios: `tab-strip-mouse` (order 310: click `new_tab` → 2 tabs; click tab 0 → active 0 and its surface `focused`; drag tab 0 past tab 1 → order swapped; middle-click tab 1 → 1 tab; after each click `GetFocus`-equivalent state shows a focused surface), `tab-rename` (order 320: double-click tab → an `Edit` child of the window exists; type `renamed` + Enter → tab title `renamed`; again + Esc → unchanged; `Invoke-GhosttyAction prompt_surface_title` → edit appears, Enter commits), `chrome-paint` (order 300: 3 tabs; foreground; `CopyFromScreen` of the strip → active tab colour ≈ config background ±6, inactive tab rects contain text pixels (luminance variance > threshold), cursor over the close caption button → its rect is mostly `#C42B1C` ±10; PNG saved to the evidence dir) — moved from Task 18; screenshots (dark + light config) attached and inspected.
- [ ] **Step 4: Verify** unit PASS; `E2E -Only tab-strip-mouse,tab-rename,chrome-paint,frame-hittest` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): tab strip mouse interaction and inline title editing"`

### Task 20: Single instance and `performIpc`

**Files:**
- Modify: `src/apprt/win32/instance.zig` (decision + forward), `src/apprt/win32/App.zig` (`init`: when the pipe claim of Task 11 failed with `AddressInUse`, decide and forward before any window; `run`/`terminate` honour `forwarded`; the pipe-owner flag drives the last-window rule; `performIpc`), `src/config/Config.zig` (core touch point: the new option only)
- Create: `test/windows/e2e/single-instance.ps1`, `test/windows/e2e/ipc-cli.ps1`

**Interfaces:**
- Consumes: Tasks 5, 8, 11.
- Produces:
  ```zig
  // Config.zig: `@"windows-single-instance": WindowsSingleInstance = .detect,` (enum { detect, true, false }; doc: Windows only, see SPEC §18.6)
  // instance.zig
  pub fn shouldForward(mode: configpkg.Config.WindowsSingleInstance, args: []const []const u8, initial_command: bool) bool;
  //   false → false; true → !initial_command and Overrides.forwardable(args) (a command is never forwarded, pre-flight 2);
  //   detect → !initial_command and Overrides.forwardable(args)
  pub fn absolutizeWorkingDirectory(arena: Allocator, args: []const []const u8, cwd: []const u8) ![]const []const u8; // relative --working-directory= → absolute (as new_window.zig does; pre-flight 7)
  pub const ForwardResult = enum { forwarded, no_server, not_our_server, failed };
  pub fn forwardNewWindow(alloc: Allocator, name: [:0]const u16, args: []const []const u8) ForwardResult; // client.request new-window, timeout 1500 ms (deadline = now + 1250)
  // App: forwarded: bool; pipe_owner: bool (= server != null);
  //   performIpc: new_window/new_tab/toggle_quick_terminal → client.request on pipeNameFor(target.class or default);
  //   NoServer → stderr "ghostty: no running Ghostty instance (class <c>)" + error.IPCFailed; NotOurServer → stderr names the squatting pid + error.IPCFailed
  ```
  Startup order (pre-flight 5): Task 11's `claim` runs first. Claimed → this process is the primary (pipe owner), never forwards. `AddressInUse` → `shouldForward` → `forwardNewWindow`: `forwarded` → exit 0 without creating a window; `not_our_server` → log `warn` (a pipe squatter, pre-flight 7) and run standalone; `no_server`/`failed` → run standalone. A process that does not own the pipe (standalone after `AddressInUse`, `--font-size=20`-style launches, `windows-single-instance = false`) never shows a tray icon and quits after its last window regardless of `quit-after-last-window-closed` (Task 28 applies the rule through `App.pipe_owner`). The second process's cwd is not forwarded (SPEC §18.6); `--working-directory=` is absolutized against it before forwarding.
- [ ] **Step 1: Failing tests** `"win32 instance: forward decision"` (detect + `{}` → true; detect + `{"--working-directory=C:\\x"}` → true; detect + `{"--title=x"}` → false; detect + `{"--font-size=20"}` → false; true + `{"--command=x"}` → false; any + initial_command → false; false → false), `"win32 instance: working directory is absolutized"` (`{"--working-directory=sub dir"}` with cwd `C:\\a` → `C:\\a\\sub dir`; absolute and UNC kept).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 instance"` → FAIL.
- [ ] **Step 3: Implement**; scenarios: `single-instance` (order 330: A started; B = same exe, same sandbox and class, `--working-directory=<sandbox>\Рабочая папка` → B exits 0 ≤ 2 s, A has 2 windows, the new shell's cwd is that dir (echo oracle via `text:cd > %TEMP%\gt-si.txt\r`); C and D launched 50 ms apart with no args while A is not running yet (fresh class) → exactly one process remains after 3 s, with 2 windows (pre-flight 5); B with `--font-size=20` → B keeps running as a separate process with no tray icon, and closing its window ends it ≤ 3 s (pre-flight 5); config `windows-single-instance = false` → separate process), `ipc-cli` (order 340: `ghostty.exe +new-window --class=<class>` exits 0 and A gains a window; unknown class → exit ≠ 0 and stderr names the class).
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build test -j2 -Dapp-runtime=none -Dtest-filter="config"` PASS; `E2E -Only single-instance,ipc-cli,shell-exit` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): single-instance forwarding and performIpc over the named pipe"`

### Task 21: Multiple windows

**Files:**
- Modify: `src/apprt/win32/actions/app_actions.zig` (`new_window`, `close_all_windows`, `goto_window`, `present_terminal`; `quit` keeps M1's `WM_GHOSTTY_QUIT` post, whose `QuitGate` handler already confirms with `core_app.needsConfirmQuit()` — no second quit path, pre-flight 4), `src/apprt/win32/actions/tab_actions.zig` (`move_tab_to_new_window`), `src/apprt/win32/Window.zig` (`placeInitial`, `create` with `first_tab = false`, `detachTab`; the `GhosttyWindow` class icon = resource id 1 from `dist/windows/ghostty.rc` instead of `IDI_APPLICATION`, pre-flight 18)
- Create: `test/windows/e2e/windows-multi.ps1`

**Interfaces:**
- Consumes: Tasks 6a, 6b, 13; Task 30 (re-parent-safe present target; `move_tab_to_new_window` re-parents a presenting surface, so it lands after Task 30 — pre-flight 3c); `window-position-x/y`.
- Produces:
  ```zig
  pub fn cascadeOrigin(parent: geom.Rect, work: geom.Rect, step: i32, size: struct { w: i32, h: i32 }) struct { x: i32, y: i32 }; // pure: parent + step, wraps to work.x/y when it would leave the work area
  pub fn placeInitial(self: *Window, parent: ?*Window) void;  // window-position-x/y on the first window; later windows cascade by the caption height from the parent (or last active)
  pub fn detachTab(self: *Window, tab: *Tab) void;           // remove from list without destroying
  ```
  Handlers: `new_window` (surface target → parent = target, context `.window`; app target → no parent), `close_all_windows` (one `CloseKind.all_windows` confirm if any window needs it, then close all confirmed), `goto_window` (`previous/next` over `app.windows` order, wraps, `SetForegroundWindow`; false with one window), `present_terminal` (restore if iconic, `SetForegroundWindow`, select the surface's tab, focus it), `move_tab_to_new_window` (false when the window has one tab; new window `first_tab = false`, `detachTab` + `tab.setWindow(new)` (SetParent of the container), select, show). The window being closed for `close_all_windows` is hidden first (`Window.beginTeardown`, Task 6b).
- [ ] **Step 1: Failing test** `"win32 window: cascade wraps inside the work area"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 window"` → FAIL.
- [ ] **Step 3: Implement**; scenario `windows-multi` (order 360: `new_window` → 2 windows, second window origin = first + step; `goto_window:next` → `GetForegroundWindow` changes (interactive only); two tabs in window 1, `move_tab_to_new_window` → 3 windows, the moved surface's `hwnd` unchanged and its shell alive (echo oracle); `close_window` → 2; `close_all_windows` → process exits ≤ 3 s (scenario config keeps `quit-after-last-window-closed = true`); the window class icon is not the generic application icon (`GetClassLongPtrW(GCLP_HICON)` ≠ `LoadIcon(null, IDI_APPLICATION)`).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only windows-multi,tabs-basic` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): multiple windows — create, cascade, goto, present, move tab to new window"`

### Task 22: Placement toggles — maximize, fullscreen, float, decorations, window size

**Files:**
- Modify (replace stub): `src/apprt/win32/placement.zig`; `src/apprt/win32/actions/window_actions.zig` (arms delegate here)
- Create: `test/windows/e2e/maximize-fullscreen.ps1`

**Interfaces:**
- Consumes: Task 17 (`frame.apply`, `stripMode`, real `nonClientSize`), `window.placement.initial_size` (stored by `Window.setInitialSize`, Task 6a). All size math goes through `frame.nonClientSize` (pre-flight 9).
- Produces:
  ```zig
  pub fn toggleMaximize(window: *Window) bool;            // IsZoomed ? SW_RESTORE : SW_MAXIMIZE
  pub fn toggleFullscreen(window: *Window) bool;          // save WINDOWPLACEMENT + GWL_STYLE, style WS_POPUP|WS_VISIBLE, monitor rect (MONITOR_DEFAULTTONEAREST), strip hidden; restore exactly
  pub fn toggleDecorations(window: *Window) bool;         // frame.decorations client|server ↔ none, frame.apply
  pub fn setFloat(window: *Window, mode: apprt.action.FloatWindow) bool; // HWND_TOPMOST / NOTOPMOST
  pub fn resetSize(window: *Window) bool;                 // re-apply initial_size; false if none
  pub fn resizeClient(window: *Window, width: u32, height: u32) bool; // ignored (false) when maximized or fullscreen; 0 keeps that dimension
  pub fn applyStartup(window: *Window) void;              // config `maximize` → SW_MAXIMIZE, `fullscreen` → toggleFullscreen after show
  pub fn fullscreenRect(monitor: geom.Rect) geom.Rect;    // pure identity today, tested to pin the contract
  ```
  `macos_non_native*` fullscreen variants behave like `native`.
- [ ] **Step 1: Failing test** `"win32 placement: resize keeps a zero dimension"` (pure `targetClient(current, requested) {w,h}`), `"win32 placement: fullscreen covers the monitor"`, `"win32 placement: window size from content size per decorations"` (pure `windowSizeFor(content, nonClient)` for client/server/none insets incl. the strip height).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 placement"` → FAIL.
- [ ] **Step 3: Implement**; scenario `maximize-fullscreen` (order 370: `toggle_fullscreen` → window rect == monitor rect, state `strip.mode = hidden`, `fullscreen = true`; again → original rect ±1; `toggle_maximize` twice → maximized then restored; `float_window:on` → `WS_EX_TOPMOST`; `toggle_window_decorations` → `decorations = none`, NCHITTEST at the former close-button point ≠ 20; config `fullscreen = true` start → fullscreen at launch; pre-flight 9: with `window-width = 80`, `window-height = 24` (cells) the surface rect from `state` is exactly 80×24 cells + padding in each of `window-decoration = client|server|none`; `resize_window` to 800×600 → content rect (below the strip) 800×600; `WM_GETMINMAXINFO` min track height includes the strip).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only maximize-fullscreen,frame-hittest` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): maximize, fullscreen, float, decorations toggle and window size actions"`

### Task 23: Per-monitor DPI for windows, tabs and chrome

**Files:**
- Modify: `src/apprt/win32/Window.zig` (`applyDpi`: update `dpi` — the single source; only window creation and `WM_DPICHANGED` read the system value, pre-flight 16 —, strip metrics, every surface of every tab (hidden ones too) `content_scale` + `contentScaleCallback` **before** `SetWindowPos(suggested)`; maximize re-applied on the new monitor), `src/apprt/win32/dpi.zig`, `src/apprt/win32/Surface.zig` (`WM_DPICHANGED_AFTERPARENT` takes the parent's dpi and skips a repeat; size change applied in the same tick as the scale — M1 Tasks 21 and 29.2 minors)
- Create: `test/windows/e2e/dpi-sim.ps1`

**Interfaces:**
- Consumes: Tasks 17, 18 (metrics, format cache by DPI), Task 11 `dpi` op. Audit (pre-flight 16): `Surface.zig` content scale, `frame.frameInsets`, `frame.nonClientSize` and `Chrome` read `window.dpi`, never `GetDpiForWindow`; `grep -n GetDpiForWindow src/apprt/win32` lists only `Window.create` and the `WM_DPICHANGED` path.
- Produces: `pub fn scaledWindowRect(rect: geom.Rect, old_dpi: u32, new_dpi: u32) geom.Rect` in `dpi.zig` (pure: keeps the top-left, scales size; used when `suggested == null`).
- [ ] **Step 1: Failing tests** `"win32 dpi: scaled window rect"` (`{100,100,800,600}` 96→144 → `{100,100,1200,900}`), `"win32 dpi: content scale for 120/144/192"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 dpi"` → FAIL.
- [ ] **Step 3: Implement**; scenario `dpi-sim` (order 380: 2 tabs (second hidden) and a zoomed split in tab 1; `dpi` op 144 → every surface `scale = 1.5` (hidden ones included), strip `bounds.h = 60`, window `cell` height ≈ 1.5× ±1; dump of the visible surface saved; 192 → 2.0; back to 96 → original cell size; after the 144 step `new_tab` and `new_split:right` → the new surfaces report `scale = 1.5` too (pre-flight 16); screenshots at 96/144/192 saved for Task 35).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only dpi-sim,resize` → PASS.
- [ ] **Step 5: Commit** `git commit -m "fix(win32): per-monitor DPI updates every surface and the chrome before resizing"`

### Task 24: Resize overlay

**Files:** Modify (replace stub) `src/apprt/win32/resize_overlay.zig`; Create `test/windows/e2e/resize-overlay.ps1`.

**Interfaces:**
- Consumes: `Chrome.shared()` (text), Task 6a hook `notify(surface, cols, rows)`, config `resize-overlay`, `resize-overlay-position`, `resize-overlay-duration`; GTK `resize_overlay.zig` for the text format and `after-first` rule.
- Produces: an owned popup per window (class `GhosttyResizeOverlay`, `WS_POPUP`, `WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW`, never focused) painted with D2D (rounded rect, palette colours), placed per position inside the surface rect, hidden by a window timer after the duration; `pub fn placement(pos: configpkg.Config.ResizeOverlayPosition, surface: geom.Rect, size: struct { w: i32, h: i32 }, margin: i32) geom.Rect` (pure).
- [ ] **Step 1: Failing test** `"win32 overlay: placement for each position"` (center, top-left, top-right, bottom-left, bottom-right, top-center, bottom-center inside a 800×600 surface with margin 8).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 overlay"` → FAIL.
- [ ] **Step 3: Implement**; scenario `resize-overlay` (order 390: `resize-overlay = always`, `resize-overlay-duration = 1s`; `Set-WindowSize` → a visible `GhosttyResizeOverlay` window of the pid within 1 s, hidden after 2.5 s; focus stays on the surface; `never` → no overlay window ever visible).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only resize-overlay` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): resize overlay popup"`

### Task 25: Native scrollbar

**Files:** Modify (replace stub) `src/apprt/win32/scrollbar.zig`; Modify `src/apprt/win32/Surface.zig` (`WS_VSCROLL` at creation when `scrollbar = system`; `WM_VSCROLL` → `scrollbar.handle`), `src/apprt/win32/actions/surface_actions.zig` (`scrollbar` arm); Create `test/windows/e2e/scrollbar.ps1`.

**Interfaces:**
- Consumes: `terminal.Scrollbar` (`total`, `offset`, `len`), `performBindingAction(.{ .scroll_to_row = n })`.
- Produces:
  ```zig
  pub fn update(surface: *Surface, value: terminal.Scrollbar) bool;   // store, SetScrollInfo(SIF_ALL|SIF_DISABLENOSCROLL) — always visible, never reflows (SPEC §18.11)
  pub fn handle(surface: *Surface, wparam: WPARAM) void;               // SB_LINEUP/DOWN ±1, PAGEUP/DOWN ±len, THUMBTRACK/THUMBPOSITION (GetScrollInfo nTrackPos, 32-bit), TOP/BOTTOM → scroll_to_row
  pub fn toScrollInfo(value: terminal.Scrollbar) win32.user32.SCROLLINFO; // pure: nMin 0, nMax total-1 (clamped to i32), nPage len, nPos offset; total > i32 range scales proportionally
  pub fn rowFor(code: u16, track: i32, state: State) ?u64;               // pure
  ```
- [ ] **Step 1: Failing tests** `"win32 scrollbar: scroll info from terminal scrollbar"` (incl. total 10^10 scaled), `"win32 scrollbar: row for each SB code"`.
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 scrollbar"` → FAIL.
- [ ] **Step 3: Implement**; scenario `scrollbar` (order 400: `cmd /c "for /L %i in (1,1,300) do @echo %i"` via `text:` → state `scrollbar.total > len`; `PostMessage(surface, WM_VSCROLL, SB_TOP)` → `offset == 0` and the dump shows the first lines; `scrollbar = never` → no `WS_VSCROLL` in the surface style).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only scrollbar,resize` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): native always-visible scrollbar bound to the terminal scrollback"`

### Task 26: Bell and taskbar progress

**Files:** Modify (replace stubs) `src/apprt/win32/bell.zig`, `src/apprt/win32/taskbar.zig`; Modify `src/apprt/win32/actions/window_actions.zig` (`ring_bell`, `progress_report`); Modify (append) `pkg/win32/shell32.zig` (`ITaskbarList3` full slot list, typed `HrInit SetProgressValue SetProgressState`, `CLSID_TaskbarList`/`IID_ITaskbarList3`, `TBPF_*`; test `"win32 shell32: ITaskbarList3 slot count"` = 21 against `shobjidl_core.h`), `pkg/win32/winmm.zig` (`PlaySoundW SND_ASYNC SND_FILENAME SND_NODEFAULT SND_PURGE`), `pkg/win32/ole32.zig` (`CoCreateInstance`, `CLSCTX_INPROC_SERVER`); Create `test/windows/e2e/bell-progress.ps1`. `Window.zig` is not edited: the caption prefix comes through `bell.decorateTitle`, which Task 13's `refreshTitle` already calls (pre-flight 3d).

**Interfaces:**
- Consumes: `bell-features` (`system`, `audio`, `attention`, `title`; `border` deferred to M3 with DComp overlays), `bell-audio-path`; `terminal.osc.Command.ProgressReport`; Task 18 bell glyph.
- Produces:
  ```zig
  pub fn ring(surface: *Surface) bool;   // title: surface.bell_ringing = true (cleared on focus, Task 6a) + the "🔔 " caption prefix via `decorateTitle`, which Task 13's `refreshTitle` calls + invalidate;
                                         // attention: FlashWindowEx(FLASHW_TRAY|FLASHW_TIMERNOFG) when the window is not foreground;
                                         // system: MessageBeep(MB_OK); audio: PlaySoundW(path, SND_ASYNC|SND_FILENAME|SND_NODEFAULT) (WAV only, volume ignored — SPEC §18.13)
  pub fn setProgress(window: *Window, report: terminal.osc.Command.ProgressReport) bool; // ITaskbarList3 (created lazily after the "TaskbarButtonCreated" message), state map remove→NOPROGRESS, set→NORMAL, error→ERROR, indeterminate→INDETERMINATE, pause→PAUSED; value 0–100; stored in window.taskbar.progress
  pub fn tbpfFor(state) u32;             // pure
  // taskbar.handle: RegisterWindowMessageW("TaskbarButtonCreated") → (re)create the interface and re-apply the stored progress
  ```
  Progress is per window: the last report from any surface of the window wins; a surface closing with progress set clears it when it was the reporter. Mirror GTK's timeout behaviour for stale reports if `gtk/class/surface.zig` has one.
- [ ] **Step 1: Failing tests** `"win32 taskbar: progress state map"`, `"win32 bell: caption prefix"` (pure `bellTitle(alloc, title, ringing) []u8`).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 taskbar"` and `"win32 bell"` → FAIL.
- [ ] **Step 3: Implement**; scenario `bell-progress` (order 410, Git Bash config, SKIP without Git Bash: `printf '\a'` from an unfocused tab → that tab `bell = true`, caption starts with the bell; select it → cleared; `printf '\e]9;4;1;40\a'` → state `progress {state:"set", value:40}`; `\e]9;4;0\a` → `progress null`).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only bell-progress` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): bell features and taskbar progress"`

### Task 27: TaskDialog confirmations

**Files:** Modify `src/apprt/win32/dialogs.zig` (`confirmCloseKind` → `TaskDialogIndirect`; `confirm` used by clipboard prompts → TaskDialog too), `src/apprt/win32/App.zig` (M1's `WM_GHOSTTY_QUIT` handler: `dialogs.confirm(…)` → `dialogs.confirmCloseKind(owner, .app)` inside the existing `QuitGate`; nothing else — pre-flight 4); Modify (append) `pkg/win32/comctl32.zig` (`TaskDialogIndirect`, `TASKDIALOGCONFIG` as `extern struct` with `align(1)` fields — the SDK declares it under `pshpack1.h`, `TASKDIALOG_BUTTON`, `TDF_*`, `TDCBF_*`, `IDOK IDCANCEL`, `InitCommonControlsEx`; test `"win32 comctl32: TASKDIALOGCONFIG is byte-packed"` with the `zig cc` provenance value moved from Task 1); Create `test/windows/e2e/close-confirm.ps1`.

**Interfaces:**
- Consumes: callers from Tasks 6b/13/21 and M1's quit handler (unchanged signatures). The tray's Quit (Task 28) posts the same `WM_GHOSTTY_QUIT`, so it gets this dialog too.
- Produces: `confirmCloseKind(owner, kind)`: title "Ghostty", main instruction per kind ("Close this terminal?", "Close this tab?", "Close this window?", "Close all windows?", "Quit Ghostty?"), content "A process is still running. Closing will end it.", custom buttons `&Close` (id 100) and `Cancel` (IDCANCEL, default), `TDF_POSITION_RELATIVE_TO_WINDOW`; returns true only for 100. `confirm(owner, title, body)` keeps its signature (Yes/No custom buttons `&Allow`/`&Cancel`, default Cancel). Falls back to the M1 `MessageBoxW` when `TaskDialogIndirect` fails. Every call site already checks that its window survived the dialog loop; the file header documents the posted-message rule (M1 Task 18 minor).
- [ ] **Step 1: Failing test** `"win32 dialogs: task dialog config is valid"` (pure `buildConfig(owner, kind, buttons) TASKDIALOGCONFIG`: `cbSize == @sizeOf(TASKDIALOGCONFIG)`, `nDefaultButton == IDCANCEL`, two buttons, flags contain `TDF_POSITION_RELATIVE_TO_WINDOW`).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 dialogs"` → FAIL.
- [ ] **Step 3: Implement**; scenario `close-confirm` (order 420: `text:ping -t 127.0.0.1\r`; `PostMessage(WM_CLOSE)` → a dialog owned by the pid appears; Esc → window stays; again → Alt+C → window closes, no orphan `PING.EXE`; shell exit behind the dialog: `text:timeout /t 4 >nul & exit\r`, post `WM_CLOSE` at once → dialog; wait 6 s (the shell exits and its tab closes behind the dialog), then Esc → no crash, process gone ≤ 5 s; `close_tab` with two tabs and a running ping → a dialog appears and Esc keeps both tabs; `quit` (ctrl+shift+q) with a running ping → the "Quit Ghostty?" task dialog appears, a second `quit` while it is up shows no second dialog (`QuitGate`), Esc keeps the process).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only close-confirm,paste-confirm` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): TaskDialog close and clipboard confirmations"`

### Task 28: Notification-area icon and last-window lifecycle

**Files:**
- Create: `src/apprt/win32/tray.zig`, `test/windows/e2e/tray.ps1`, `test/windows/e2e/quit-after-last.ps1`
- Modify: `src/apprt/win32/App.zig` (`tray: tray.State`, created after the first window only when `pipe_owner`, destroyed in `terminate`; `windowDestroyed` → `lastWindowAction` — today it always quits, which is the only real bug here; `startQuitTimer` doc fixed — M1 Task 14 minor; `test { _ = tray; }`), `src/config/Config.zig` (core touch point: one doc sentence — the default is already `false` on Windows via `os == .linux` at `Config.zig:2645`, so no code change; pre-flight 4), `src/apprt/win32/actions/app_actions.zig` (`config_change` → `tray.sync`), `src/apprt/win32/ipc/ops.zig` (state gains `"tray":{"visible":bool}` and `"pipe_owner":bool`; a state with no window answers `"windows":[]`)
- Modify (append): `pkg/win32/shell32.zig` (`Shell_NotifyIconW`, `NOTIFYICONDATAW` + `zig cc` provenance size test moved from Task 1, `NIM_* NIF_* NOTIFYICON_VERSION_4 NIN_SELECT NIN_KEYSELECT`)

**Interfaces:**
- Consumes: Task 1 (menu bindings), Task 20 (`pipe_owner`, forwarding), Task 21 (`new_window`, `present_terminal`), Task 27 (quit dialog), Task 15 (`theme.settingChanged`), core `quit_timer` start/stop.
- Produces:
  ```zig
  // tray.zig
  pub const State = struct { hwnd: ?HWND = null, visible: bool = false, taskbar_created: u32 = 0, icon: ?HICON = null };
  pub fn init(app: *App) !void;   // hidden top-level tool window, class GhosttyTray (never shown; receives "TaskbarCreated"), icon from the exe resources, tip "Ghostty"
  pub fn sync(app: *App) void;    // visible ⇔ !config.@"quit-after-last-window-closed": NIM_ADD + NIM_SETVERSION(NOTIFYICON_VERSION_4) / NIM_DELETE
  pub fn deinit(app: *App) void;  // NIM_DELETE, DestroyIcon, DestroyWindow
  pub const menu_new_window: u32 = 1;
  pub const menu_quit: u32 = 2;
  pub fn clickAction(windows: usize) enum { present_last, new_window };  // pure; left click = NIN_SELECT / NIN_KEYSELECT
  // WM_GHOSTTY_TRAY (LOWORD(lParam) = event): NIN_SELECT|NIN_KEYSELECT → clickAction; WM_CONTEXTMENU → SetForegroundWindow(tray hwnd),
  //   TrackPopupMenuEx(TPM_RETURNCMD|TPM_RIGHTBUTTON) with "New Window", separator, "Quit"; WM_COMMAND with the menu ids does the same (e2e posts it);
  //   "TaskbarCreated" → NIM_ADD again. Quit: posts M1's WM_GHOSTTY_QUIT (QuitGate + Task 27 dialog; no window → quits at once)
  // Menu (pre-flight 18): SetForegroundWindow(tray hwnd) before TrackPopupMenuEx and PostMessageW(tray hwnd, WM_NULL) after it (menu-dismiss bug).
  // Elevated: ChangeWindowMessageFilterEx(tray hwnd, "TaskbarCreated" and "TaskbarButtonCreated", MSGFLT_ALLOW).
  // Icon: LoadImageW(resource id 1 of dist/windows/ghostty.rc, SM_CXSMICON at the tray dpi).
  // WM_SETTINGCHANGE on the tray window → theme.settingChanged(app, lparam), so a light/dark switch with 0 windows is not missed (pre-flight 19).
  // WM_QUERYENDSESSION → TRUE without any dialog; WM_ENDSESSION(TRUE) → quit cleanly (terminate without confirmations) (pre-flight 18).
  // App.zig
  pub fn lastWindowAction(quit_after: bool, delay_ms: ?u32, pipe_owner: bool) enum { quit_now, quit_timer, stay };  // pure; !pipe_owner → quit_now (pre-flight 5)
  //   windowDestroyed with no window left: quit_now → PostQuitMessage; quit_timer → the M1 timer (core's quit_timer start/stop still honoured);
  //   stay → nothing (tray icon + pipe keep the process reachable)
  ```
- [ ] **Step 1: Failing tests** `"win32 app: last window policy"` (`(true, null, true)` → quit_now; `(true, 1000, true)` → quit_timer; `(false, null, true)` and `(false, 1000, true)` → stay; `(false, null, false)` → quit_now), `"win32 tray: click action"` (0 windows → new_window; 2 → present_last).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 app"` and `"win32 tray"` → FAIL.
- [ ] **Step 3: Implement**; scenarios (`milestone=M2`): `tray` (order 430, `Start-E2eGhostty -KeepDefaultQuit`: state `tray.visible = true`; close the only window → process alive after 3 s and state `windows = []`; `PostMessage(<GhosttyTray window of the pid>, WM_GHOSTTY_TRAY, 0, NIN_SELECT)` → a window appears ≤ 2 s; close it; `PostMessage(WM_COMMAND, menu_new_window)` → a window; a second launch of the same class forwards → 2 windows; `PostMessage(WM_COMMAND, menu_quit)` with idle shells → process exits ≤ 3 s; `-e`-style separate process (`--font-size=20` launch of the same class) → no tray icon of its own, ends with its window), `quit-after-last` (order 440: `quit-after-last-window-closed = true` → `tray.visible = false` and closing the last window ends the process ≤ 3 s; with `quit-after-last-window-closed-delay = 2s` the process is alive at 1 s and gone by 4 s; a `new-window` IPC inside the delay keeps it running).
- [ ] **Step 4: Verify** unit PASS; `LOCK ZIG build test -j2 -Dapp-runtime=none -Dtest-filter="config"` PASS; `E2E -Only tray,quit-after-last,single-instance,shell-exit` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): notification-area icon; keep running after the last window by default on Windows"`

### Task 29: Tab-close process semantics (Windows Terminal behaviour)

**Files:**
- Modify: `src/Command.zig` (Windows: `killTree` → `killChild`: terminate the direct child only; drop the job walk and `shouldKill`; keep the job object and `jobProcessIds` for process listing (M4 pane queries); keep `fileSubsystem` only if still used), `src/termio/Exec.zig` (`killCommand` calls `killChild`, then closes the pseudo console right away so `ClosePseudoConsole` sends `CTRL_CLOSE_EVENT` to the console clients attached to that surface; the M1 drain-to-EOF bound is unchanged)
- Modify: `test/windows/e2e/close-tree.ps1`, `test/windows/e2e/_common.ps1` (`Assert-NoSurvivors -Except [int[]]`; `Start-SurvivorConsole($G)` types `cmd //c start "gt-survivor-<hex>" cmd /k` into Git Bash and returns the new `cmd.exe` pid, found by its command line; `Stop-Survivor` kills it and its `conhost.exe`, always called from `finally`)
- Create: `test/windows/e2e/tab-close-tree.ps1`

**Interfaces:**
- Consumes: M1 `Command` job and ConPTY close path (`src/pty.zig`), Task 11 oracle, Task 13 tabs, Tasks 36/37's Windows-only edits in `Exec.zig` (keep them). The process-handle leak of the M1 final review (M1) is already fixed (538506c09); keep its `closeProcess` call on the new path.
- Produces: `pub fn killChild(self: *Command) !void` (Windows) and the behaviour of SPEC §18.14: closing a surface (split, tab or window) ends its shell and every console client attached to its pseudo console; programs with their own console (`start cmd`, `start python x.py`), detached processes and GUI programs keep running.
- [ ] **Step 1: Failing tests** (`-Dapp-runtime=none`)
  ```zig
  test "windows command: killChild ends only the direct child" { // cmd /c "start /min cmd /k & ping -n 30 127.0.0.1" without a pseudo console: after killChild the child is gone, the started cmd.exe (own console) is alive; the test terminates it }
  test "windows exec: closing the pseudo console ends attached console clients" { // pty + cmd /k ping -n 60 127.0.0.1; ping pid from jobProcessIds; killChild + close the pseudo console → ping.exe gone within 6 s }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dapp-runtime=none -Dtest-filter="windows command"` and `"windows exec"` → FAIL.
- [ ] **Step 3: Implement**; scenarios: `close-tree` (stays `milestone=M1`, rewritten: ping in Git Bash plus `Start-SurvivorConsole`; close the window → `bash.exe`, `ping.exe` and the surface's `OpenConsole.exe`/`conhost.exe` gone ≤ 6 s; the survivor `cmd.exe` alive; `Assert-NoSurvivors -Except <survivor, its conhost>`; survivor stopped in `finally`), `tab-close-tree` (order 450, M2, scenario config `confirm-close-surface = false`: two tabs; ping and a survivor started in tab 1; `close_tab:this` on tab 1 → its shell and ping gone ≤ 6 s, tab 0's shell alive (echo oracle), survivor alive, then stopped).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only close-tree,tab-close-tree,close-while-streaming,shell-exit` → PASS.
- [ ] **Step 5: Commit** `git commit -m "fix(windows): closing a tab ends its shell and pseudo-console clients only (Windows Terminal semantics)"`

### Task 30: Re-parent-safe present target (swap chain recreated after a move)

Runs in W7, before Task 21 (`move_tab_to_new_window`) and Task 32 re-parent presenting surfaces (pre-flight 3c). If Task 12's spike check (c) showed that `SetParent` keeps a flip-model swap chain presenting, this task still lands, but the render thread recreates only when the bumped generation is followed by a failed present (`DXGI_ERROR_INVALID_CALL`, `E_ACCESSDENIED`) — a defensive path instead of a recreation on every move (pre-flight 10, 23).

**Files:** Modify `src/renderer/D3D11.zig` (`PresentTarget.generation`; the render thread recreates its swap chain when the generation changed), `src/renderer/d3d11/SwapChain.zig` (recreation helpers: close the old waitable, reset pacing state), `src/apprt/win32/Surface.zig` (`present_generation` field, `bumpPresentTarget`; `Surface.window` becomes an atomic pointer or is read only on the UI thread — audit below).

**Interfaces:**
- Consumes: M1 `SwapChain.init/deinit`, `PresentTarget`, core `Surface.refreshCallback`; Task 37's pacing counter (unchanged).
- Produces:
  ```zig
  // D3D11.zig
  pub const PresentTarget = struct { hwnd: *anyopaque, size: *const std.atomic.Value(u64), id: u32,
      generation: *const std.atomic.Value(u32) };  // bumped by the apprt after the HWND changed parents
  // swap chain getter (render thread): generation != swap_chain_generation → recreate before the frame uses it, under the context lock:
  //   context ClearState + Flush, release every back-buffer RTV/texture reference, SwapChain.deinit (closes the frame-latency waitable),
  //   CreateSwapChainForHwnd on the same hwnd, MakeWindowAssociation again, pacing state reset (pre-flight 21: deferred destruction
  //   otherwise makes CreateSwapChainForHwnd fail with E_ACCESSDENIED)
  // Surface.zig
  present_generation: std.atomic.Value(u32) = .init(0),
  pub fn bumpPresentTarget(self: *Surface) void;  // UI thread: fetchAdd(1, .release), then core_surface.refreshCallback() so a frame follows
  ```
  Re-parenting never touches DXGI on the UI thread (SPEC §5); the render thread does the recreation (SPEC §18.16). Audit (pre-flight 21): list every read of `Surface.window` / `rtApp()` reachable off the UI thread (renderer and IO callbacks); each either goes through the app pointer (stable) or is moved to the UI thread. `Tab.setWindow` (Task 32) rewrites `surface.window` while those threads run.
- [ ] **Step 1: Failing tests** (WARP, hidden test HWNDs)
  ```zig
  test "d3d11 swapchain: generation bump recreates the swap chain after SetParent" { // child of parent A presents; SetParent(child, B); bump; next frame: new swap chain object, present OK, back-buffer readback == target }
  test "d3d11 swapchain: recreation releases every back-buffer reference first" { // debug-layer/refcount check: old swap chain's final Release returns 0 before the new one is created }
  test "d3d11 swapchain: no recreation without a bump" { // 5 frames, same swap chain object }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dapp-runtime=none -Dtest-filter="d3d11 swapchain"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** PASS; `LOCK ZIG build -j2`; `E2E -Only render,resize,resize-while-streaming,input-latency` → PASS (the window-level re-parent e2e runs in Task 21's `windows-multi`).
- [ ] **Step 5: Commit** `git commit -m "feat(d3d11): recreate the swap chain on the render thread after the surface window is re-parented"`

### Task 31: Tab drag state machine and drag ghost

**Files:** Modify (replace stubs) `src/apprt/win32/tab_drag.zig`, `src/apprt/win32/drag_ghost.zig`.

**Interfaces:**
- Consumes: `TabStrip.Metrics` (`drag_threshold`), `Chrome.paintTabChip` (Task 18), Task 1 layered-window bindings.
- Produces:
  ```zig
  // tab_drag.zig (pure; all coordinates in screen pixels)
  pub const Point = struct { x: i32, y: i32 };
  pub const Hit = union(enum) { none, strip: struct { window: u32, index: usize } };  // index = insertion slot under the cursor
  pub const Event = union(enum) { move: struct { pt: Point, hit: Hit }, release, cancel };  // cancel = Esc or capture lost
  pub const Outcome = union(enum) { click, reorder: struct { from: usize, to: usize }, move_to: struct { window: u32, index: usize },
      tear_off: Point /* new window origin */, move_window: Point /* single-tab source */, cancelled: struct { restore_index: usize } };
  pub const Feedback = struct { live_reorder: ?struct { from: usize, to: usize } = null, ghost: ?Point = null,
      marker: ?struct { window: u32, index: usize } = null, done: ?Outcome = null };
  pub const Machine = struct {
      pub fn begin(source_window: u32, tab: usize, tab_count: usize, press: Point, grab: Point /* cursor offset inside the tab */,
          strip_origin: Point /* source strip top-left */, threshold: i32, detach_margin: i32) Machine;
      pub fn feed(self: *Machine, ev: Event) Feedback;
  };
  pub fn detachMargin(dpi: u32) i32;   // geom.scale(24, dpi)
  ```
  States `pressed → in_strip → detached`. `pressed` stays until the cursor moves beyond `threshold`; then over the own strip → `in_strip` (live reorder feedback, as Task 10's drag rules), elsewhere → `detached`. `in_strip` → `detached` when the hit is not the own strip and the cursor is more than `detach_margin` outside the source strip bounds; `detached` over the own strip → back to `in_strip`. `detached`: `ghost = pt - grab`; over another window's strip → `marker`. Release: `pressed` → `click`; `in_strip` → `reorder` (the final from/to, possibly equal); `detached` over another strip → `move_to`; `detached` over nothing → `tear_off(pt - grab - strip_origin_offset)` or `move_window(...)` when `tab_count == 1`. `cancel` in any drag state → `cancelled` with the index the tab had at `begin`.
  ```zig
  // drag_ghost.zig
  pub fn show(app: *App, title: []const u8, size: geom.Rect, at: tab_drag.Point) void; // one per process: WS_POPUP, WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE|WS_EX_TOPMOST
  pub fn moveTo(at: tab_drag.Point) void;   // SetWindowPos without activation
  pub fn hide() void;
  // content: Chrome.paintTabChip into a premultiplied 32bpp DIB, UpdateLayeredWindow(ULW_ALPHA, constant alpha 0xD8);
  // WS_EX_TRANSPARENT keeps it out of WindowFromPoint; WM_DPICHANGED (moving across monitors) repaints at the new dpi
  ```
- [ ] **Step 1: Failing tests**
  ```zig
  test "win32 tab drag: press and release without moving is a click" {}
  test "win32 tab drag: below threshold stays pressed" {}
  test "win32 tab drag: reorder inside the own strip" { // live_reorder {0,1}, release → reorder {0,1} }
  test "win32 tab drag: leaving the strip by the margin detaches and shows the ghost" { // y = strip bottom + margin + 1, hit none → ghost = pt - grab }
  test "win32 tab drag: back over the own strip re-attaches" {}
  test "win32 tab drag: drop on another window's strip" { // marker {7, 1}; release → move_to {7, 1} }
  test "win32 tab drag: drop outside tears off, single tab moves the window" {}
  test "win32 tab drag: Esc restores the original index" { // after live reorder 0→2, cancel → cancelled{restore_index 0} }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 tab drag"` → FAIL.
- [ ] **Step 3: Implement** (the ghost has no unit test beyond compiling; Task 32's scenario shows it).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): tab drag state machine and layered drag ghost"`

### Task 32: Tab tear-off and re-dock across windows

**Files:**
- Modify: `src/apprt/win32/strip_input.zig` (drag through `tab_drag.Machine` with capture on the source window; cross-window hit testing; ghost; Esc), `src/apprt/win32/Window.zig` (`insertTab`, `createForTearOff`), `src/apprt/win32/Tab.zig` (`setWindow` also rescales surfaces when the dpi differs and calls `bumpPresentTarget` on each surface)
- Uses (no edit): `test/windows/lib/MouseInput.psm1` down/move/up primitives from Task 19.
- Create: `test/windows/e2e/tab-drag.ps1`

**Interfaces:**
- Consumes: Tasks 19 (strip input), 21 (`detachTab`, `move_tab_to_new_window` path), 30 (`bumpPresentTarget`), 31 (machine, ghost), Task 18 (drop marker from `strip_input.State.drop_index`).
- Produces:
  ```zig
  // strip_input.zig
  pub fn hitAt(app: *App, pt: tab_drag.Point) tab_drag.Hit;
  //   WindowFromPoint → GetAncestor(GA_ROOT) → must be one of app.windows (class GhosttyWindow of this process; other processes are never targets)
  //   → ScreenToClient → that window's strip.hitTest → insertion index = slot whose centre is right of x (count when past the last tab)
  // drag start (threshold passed): SetCapture(source hwnd); SetFocus(source hwnd) so Esc reaches it (WM_SETFOCUS redirect to the surface is
  //   suppressed while dragging); WM_KEYDOWN VK_ESCAPE → cancel; WM_CAPTURECHANGED → cancel; WM_LBUTTONUP → release
  // feedback: live_reorder → window.moveTab; marker → target window strip_input.drop_index + Chrome.invalidate (cleared on leave);
  //   ghost → drag_ghost.show/moveTo/hide
  // outcomes: move_to → source.detachTab, target.insertTab(tab, index), tab.setWindow(target), select it, SetForegroundWindow(target);
  //   tear_off → createForTearOff(app, origin, source size) + detachTab/insertTab/setWindow + show;
  //   move_window → SetWindowPos(source) to the origin; cancelled → moveTab back to restore_index;
  //   afterwards: source with no tab → requestClose(true) (last-window rule of Task 28 applies only if no window remains); focus the moved tab's surface
  // Window.zig
  pub fn insertTab(self: *Window, tab: *Tab, index: usize) void;           // clamp index, select, layout, refreshTitle
  pub fn createForTearOff(app: *App, origin: tab_drag.Point, size: struct { w: i32, h: i32 }) !*Window; // first_tab = false, placed at origin (dpi of the monitor there)
  // Tab.zig
  pub fn setWindow(self: *Tab, window: *Window) void;  // SetParent(container); every surface: window = window; dpi differs → content scale + contentScaleCallback; bumpPresentTarget
  ```
  The core surface, its pty and its child process never restart: only HWND parents change.
- [ ] **Step 1: Failing test** `"win32 strip input: insertion index from x"` (pure `insertionIndex(tabs: []const geom.Rect, x: i32) usize`: left of tab 0 centre → 0, between centres → 1, past the last → count).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 strip input"` → FAIL.
- [ ] **Step 3: Implement**; scenario `tab-drag` (order 460, cmd config, interactive only: window A placed first at a fixed position inside the primary monitor's work area, at most half its height, so "250 px below its bottom" is on-screen and off the taskbar (pre-flight 20); window A with tabs T0, T1; record the `cmd.exe` pids of both shells (process tree) and T1's surface `hwnd`; `Send-MouseDown` on T1's centre, `Send-MouseMove` to 250 px below A's bottom edge in 25 steps, check a visible `GhosttyDragGhost` window of the pid, hold 300 ms, `Send-MouseUp` → 2 windows, each with one tab, T1's surface `hwnd` unchanged, both `cmd.exe` pids alive and unchanged, echo oracle in T1 works, a `GhosttyDragGhost` window was visible mid-drag and is hidden after; drag T1 from the new window onto A's strip right of T0 → 1 window with tabs [T0, T1], the new window gone, pids unchanged; drag T0 out and press Esc before releasing → still 1 window, order unchanged).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only tab-drag,tab-strip-mouse,windows-multi` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): drag tabs out into new windows and onto other windows"`

### Task 36: Latency measurement — input path, output path, TUI scrolling, ConPTY variants (W1, first task of M2)

Owner requirement (DECISIONS, 2026-10-26) and owner update the same day: typing lags in Debug **and** in ReleaseFast (`C:\D\den4ik\Ghostty-try\release\bin\ghostty.exe`), and input lag is high in TUI apps when scrolling with the mouse wheel and navigating. This task measures before anything is changed and names the causes; Task 37 fixes what is inside Ghostty, Task 40 what is in ConPTY. It runs in W1 next to Tasks 2 and 3 (file-disjoint: it owns the renderer, `Surface.zig`, `keyboard.zig`, `mouse.zig` and the Windows pty/termio files in this wave).

**Acceptance thresholds** (owner decision 2026-10-26: whole path ≤ 16 ms p95 on ReleaseFast; Ghostty-owned stages ≤ 6 ms; Debug may stay slower, daily use is ReleaseFast; gated in Tasks 37/40, recorded here). p95 over the stated sample, primary monitor at its native refresh rate, Git Bash. Debug numbers are recorded against the target column, not gated:

| Scenario | Measured span | ReleaseFast gate | Debug target (recorded) |
|---|---|---|---|
| (a) key echo, idle shell, 200 keys 120 ms apart | keypress → present of the echo | ≤ 16 ms | ≤ 50 ms |
| (b1) key navigation in `less` (`j`, `k`, `Space`, `b`) and `vim` (`j`, `Ctrl-E`, `Ctrl-D`) on a 50 000-line file, 100 keys 150 ms apart | keypress → present of the changed screen | ≤ 16 ms | ≤ 60 ms |
| (b2) mouse wheel in `less` and `vim` (mouse mode on), 60 notches 50 ms apart | notch → present of the scrolled screen | ≤ 16 ms | ≤ 60 ms |
| (b3) wheel burst: 30 notches 8 ms apart | last notch → last present (no backlog) | ≤ 50 ms | ≤ 120 ms |
| (c) output → present, idle: `while :; do date +%s%N; sleep 0.1; done`, 200 lines | pty read → present | ≤ 8 ms | ≤ 25 ms |
| (c2) output → present with 3 other panes streaming (Task 14 adds it to `split-many`) | pty read → present | ≤ 20 ms | recorded |
| all of (a)–(c) | Ghostty-owned stages: input → pty write + pty output → present | ≤ 6 ms | recorded |

A threshold may change only with the stage table and the lead's written sign-off. The ConPTY stage (pty write → pty output) is reported separately: when ConPTY + shell alone make (a) or (b1)/(b2) exceed 16 ms, Task 40 is mandatory (passthrough mode or bundled OpenConsole, as Windows Terminal does); otherwise the lead may mark Task 40 N/A. The owner also compares Ghostty against Windows Terminal by hand on the same machine (exit checklist).

**Files:**
- Create: `src/os/windows_latency.zig` (std only; core touch point), `test/windows/e2e/input-latency.ps1`, `test/windows/e2e/tui-latency.ps1`, `test/windows/e2e/output-latency.ps1`, `test/windows/e2e/_latency.ps1` (shared helpers: CSV parse, percentiles, baseline row), `docs/windows/latency-baseline.csv`
- Modify: `src/os/main.zig` (export `windows_latency`); `src/apprt/win32/keyboard.zig` (`markInput(.key)` at `WM_KEYDOWN`/`WM_SYSKEYDOWN`/`WM_CHAR` entry); `src/apprt/win32/mouse.zig` (`markInput(.wheel)` at `WM_MOUSEWHEEL`/`WM_MOUSEHWHEEL`, counters: wheel messages, `scrollCallback` calls); `src/apprt/win32/Surface.zig` (`d3d11PresentTarget` fills `id` — the seam moved here from Task 2); `src/renderer/D3D11.zig` (`PresentTarget.id: u32`; `markRenderStart` at `beginFrame` entry; `markSlotWait(ns)` around the frame-slot wait; no behaviour change); `src/renderer/d3d11/SwapChain.zig` (`markPresent(id)` right after `Present` returns); `src/termio/Exec.zig` (Windows-only paths: `markWrite` + bytes after each pty `WriteFile`, `markOutput` + bytes when the overlapped read returns, `markParsed` after the `processOutput` slices of that read with the slice count and the `yieldToDemand` count, `GHOSTTY_LATENCY_TRACE` removed from the child environment); `src/pty.zig` + `src/os/windows.zig` (diagnostic only, Windows: `GHOSTTY_WIN32_CONPTY_FLAGS=<u32>` passed to `CreatePseudoConsole` instead of 0 — an `E_INVALIDARG` is logged and retried with 0; `GHOSTTY_WIN32_CONPTY_DLL=<path to conpty.dll>` loads `CreatePseudoConsole`/`ResizePseudoConsole`/`ClosePseudoConsole` from that DLL via `LoadLibraryExW(LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR)` + `GetProcAddress`, falling back to kernel32 on any failure)

**Interfaces:**
- Produces:
  ```zig
  // src/os/windows_latency.zig — std only, no win32 import (core rule); every mark is one relaxed atomic load when off
  pub fn enabled() bool;                       // GHOSTTY_LATENCY_TRACE=<csv path>, read once (lazy, thread-safe)
  pub const InputKind = enum { key, wheel };
  pub fn markInput(kind: InputKind) void;      // UI thread; std.Io.Timestamp (QPC-backed awake clock); opens a sample
  pub fn markWrite(bytes: usize) void;         // IO side: pty write after an open input (counts writes per input)
  pub fn markOutput(bytes: usize) void;        // read loop: pty bytes; opens an output-only sample when no input is open (scenario c)
  pub fn markParsed(slices: u32, yields: u32) void; // after processOutput of that read
  pub fn markRenderStart() void;               // render thread: frame begins (renderer wakeup → draw latency)
  pub fn markSlotWait(ns: u64) void;           // render thread: frame-slot wait of this frame
  pub fn markPresent(surface_id: u32) void;    // render thread: first present after output closes the sample
  pub const Sample = struct { kind: enum { key, wheel, output }, t0_ns: u64,
      input_to_write_ns: u64, write_to_output_ns: u64, output_to_parsed_ns: u64, parsed_to_render_ns: u64,
      slot_wait_ns: u64, render_to_present_ns: u64, total_ns: u64,
      writes: u32, write_bytes: u64, output_bytes: u64, slices: u32, yields: u32, presents_between: u32, surface: u32 };
  pub fn stats(values: []const u64) struct { n: usize, p50: u64, p95: u64, max: u64 }; // pure
  // CSV: one line per sample (diagnostic mode only), all stage columns in ms with 3 decimals, plus build + scenario tag
  ```
  Sample rules: an input sample closes at the first present after the first output that follows its first write; inputs without a write (modifiers) are dropped after 500 ms; a new input while one is open closes the old one as `incomplete` (counted, excluded from percentiles); `presents_between` counts presents after the input and before the closing one (the keypress repaint shows up here); the burst metric (b3) is computed by the script from the last wheel `t0` and the last present.
  Scenarios (each runnable alone through `Invoke-E2eScenario` before Task 4's runner exists; headers `# e2e: milestone=M2 timeout=300 order=150|151|152`; Git Bash required, SKIP without it; the script sets `$env:GHOSTTY_LATENCY_TRACE` in its own process before `Start-E2eGhostty` and clears it after; `_common.ps1` is not edited): `input-latency` (a); `tui-latency` (b1–b3: generates a 50 000-line file in the sandbox, runs `less` then `vim -u NONE -c 'set mouse=a'`, real `SendInput` keys and `MOUSEEVENTF_WHEEL` notches over the surface; `vim`/`less` absent → that half SKIPs); `output-latency` (c). Each records harness QPC before every `SendInput` (dispatch delay = Ghostty `markInput` − harness stamp, same clock), prints per-stage p50/p95/max, appends rows to `docs/windows/latency-baseline.csv` (`date, commit, optimize, adapter, refresh_hz, conpty, scenario, stage, p50_ms, p95_ms, max_ms, n`), and in this task only records.
- [ ] **Step 1: Failing tests** in `windows_latency.zig`:
  ```zig
  test "windows latency: a complete key sample has ordered stages" { // fake clock: input 0, write 1, output 4, parsed 5, render 6, slot wait 2, present 9 → stages and total 9 ms }
  test "windows latency: present before output does not close the sample" { // the keypress repaint is counted in presents_between, not used as the echo }
  test "windows latency: wheel input counts writes" { // one wheel input, 3 writes → writes 3 }
  test "windows latency: output-only sample" { // output with no open input → kind output, closed at the next present }
  test "windows latency: stats percentiles" { // 1..100 → p50 50, p95 95, max 100 }
  test "windows latency: disabled marks are no-ops" {}
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dapp-runtime=none -Dtest-filter="windows latency"` → FAIL.
- [ ] **Step 3: Implement** the tracer, the marks, the diagnostic ConPTY overrides, the three scenarios.
- [ ] **Step 4: Measure** (no fixes in this task) on Debug (`LOCK ZIG build -j2`) and ReleaseFast (`LOCK ZIG build -j2 -Doptimize=ReleaseFast --prefix zig-out-rf`), all three scenarios, and for (a) and (b1) also with ConPTY variants: inbox flags `0`; `GHOSTTY_WIN32_CONPTY_FLAGS` = 2 (`PSEUDOCONSOLE_RESIZE_QUIRK`), 4 (`PSEUDOCONSOLE_WIN32_INPUT_MODE`), 8 (`PSEUDOCONSOLE_PASSTHROUGH_MODE`; record whether the inbox conhost of this build accepts it); and, only with the lead's approval of the download, `GHOSTTY_WIN32_CONPTY_DLL` pointing at `conpty.dll` + `OpenConsole.exe` from the official `Microsoft.Windows.Console.ConPTY` NuGet package (MIT; exact version and SHA-256 recorded; unpacked into the scratch dir, never installed system-wide) with flags 0 and 8. Report: per scenario and build the stage table; the ConPTY stage per variant; wheel coalescing (`WM_MOUSEWHEEL` messages vs `scrollCallback` calls vs pty writes vs bytes per notch in mouse mode and in alternate-scroll mode); `processOutput` slices and `yieldToDemand` calls per read and the parse stage cost per KiB; renderer wakeup → render start (timer cadence) and the frame-slot wait share; Debug-only costs. A ranked list of causes for Task 37 (inside Ghostty) and a go/no-go for Task 40 (ConPTY) with the evidence. Candidates to confirm or rule out: (1) the ≤ 100 ms frame-slot wait after the keypress repaint used the only slot (`SetMaximumFrameLatency(1)`, vsynced `Present`); (2) renderer wakeup/coalescing and timer cadence; (3) wheel events not coalesced: one `scrollCallback` and one pty write per `WM_MOUSEWHEEL`, each followed by a frame; (4) the 2 KiB `processOutput` slicing + `yieldToDemand` per slice on big TUI redraws; (5) `WM_CHAR` draining; (6) Debug-only costs; (7) ConPTY's render cadence and VT re-encoding (inbox conhost repaints on its own timer; passthrough mode / OpenConsole avoid it).
- [ ] **Step 5: Commit** `git commit -m "test(windows): latency tracer, input/TUI/output probes, ConPTY variants and baseline"` (body: the stage tables and the go/no-go for Task 40).

### Task 37: Latency fixes inside Ghostty (W4)

**Files:**
- Modify: `src/renderer/D3D11.zig`, `src/renderer/d3d11/SwapChain.zig` (also moves its local `WaitForSingleObjectEx`/`CloseHandle` externs to `pkg/win32`, Task 1's declarations), `src/renderer/d3d11/Frame.zig`, `src/apprt/win32/keyboard.zig`, `src/apprt/win32/mouse.zig` (wheel coalescing; also moves its local `SystemParametersInfoW`/`GetClassNameW` externs), `src/termio/Exec.zig` (Windows-only read path: slice size and yield policy, only if Task 36 measured them as a cause), the latency scripts (thresholds become gates), `docs/windows/latency-baseline.csv`
- Modify only if Task 36 selects it: `src/build/SharedDeps.zig` (Windows-gated: C dependencies built `ReleaseFast` in Debug builds; core touch point). A cause outside these files (core `src/renderer/Thread.zig`, `src/Surface.zig`, `src/termio/Termio.zig`) is not fixed here: the implementer stops with the evidence and the lead schedules a 37.n task (those files are shared with macOS/Linux; changes must be platform-neutral or gated and are reviewed separately).

**Interfaces:**
- Consumes: Task 36 tracer, scenarios and ranked causes; M1 final review M4 and pre-flight 22 (these files): `waitForSlot`'s `presented_since_wait` bool drifts with more than one present between waits → a pending-present counter (incremented per `Present`, consumed per successful wait, never negative, capped at the frame latency); `draw_mutex` is not held across the frame-slot wait.
- Produces (each fix backed by a stage-table delta in the report; one commit per cause):
  - Pacing: no frame-slot wait when the swap chain has been idle for ≥ 1 refresh interval (skip the kernel wait and the context unlock/lock pair). If `presents_between > 0` and the slot wait dominate (the keypress or wheel repaint used the only slot just before the echo), the fix stays inside the D3D11 backend: frame latency 2 for the first frame after input, or that frame presented with sync interval 0 on the flip-model swap chain (DWM shows the newest frame at the next vblank). `frame_slot_wait_ms` stays a bound, not a pacing mechanism.
  - Wheel: `WM_MOUSEWHEEL` deltas accumulate per surface and are delivered as one `scrollCallback` per UI message-loop turn (drain queued wheel messages for the same surface with `PeekMessageW(PM_REMOVE)` first), so a burst produces one pty write per turn instead of one per notch; precision-touchpad deltas (< 120) keep their fractional remainder; Shift+wheel and `WM_MOUSEHWHEEL` unchanged. Gate (b3).
  - Input: `WM_CHAR` draining does one `PeekMessageW(PM_REMOVE)` pass per key; input → write ≤ 1 ms p95 on ReleaseFast.
  - Output path: if (4) is confirmed, the Windows read loop parses one read in larger slices (bounded so a quit request is still seen within the M1 bound) and yields to the renderer at most once per read instead of per slice; `stream-integrity` and `close-while-streaming` stay green.
  - Debug: if C dependencies dominate Debug CPU time, build them `ReleaseFast` in Debug on Windows (SharedDeps, gated); if Zig code under `slow_runtime_safety` dominates, record it.
  - `GHOSTTY_D3D11_PACING_LOG=1` (diagnostic): one `log.debug` line per frame with slot-wait and build durations.
- Acceptance: the Task 36 ReleaseFast gates for (a), (b1), (b2), (b3), (c) and the Ghostty-owned ≤ 6 ms row, measured with the inbox ConPTY — except that a scenario whose ConPTY stage alone breaks its budget is gated here on the Ghostty-owned row only and on the full span in Task 40; Debug numbers recorded against the target column. No regression: idle CPU of a 1-surface window unchanged (±0.5 % over 30 s), `stream-integrity`, `resize-while-streaming`, `close-while-streaming`, `vim-less` PASS.
- [ ] **Step 1: Failing tests**
  ```zig
  test "d3d11 swapchain: pending presents are counted, not a bool" { // 2 presents, 1 successful wait → 1 pending; timed-out waits never underflow }
  test "d3d11 frame slot: no wait after an idle interval" { // fake clock + fake waitable: last present > refresh interval ago → wait not called }
  test "d3d11 frame slot: draw_mutex is not held during the wait" { // a second thread takes draw_mutex while the render thread waits on a never-signalled waitable (bounded 50 ms) → succeeds }
  test "win32 mouse: wheel deltas coalesce per surface" { // pure accumulator: +120 ×5 in one turn → one delivery of 5 notches; +40 +40 → none, +40 → one; direction change flushes }
  // plus one failing test per further fix selected from the Task 36 ranking, written before that fix
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dapp-runtime=none -Dtest-filter="d3d11 "` and `LOCK ZIG build test -j2 -Dtest-filter="win32 mouse"` → FAIL.
- [ ] **Step 3: Implement** in the order of the Task 36 ranking, re-measuring after each.
- [ ] **Step 4: Verify** unit PASS; `grep -rn 'extern "' src/apprt/win32 src/renderer/d3d11` → no output; the three latency scenarios gate on ReleaseFast as above and record Debug; `E2E -Milestone M1` PASS; baseline rows appended (after-fix).
- [ ] **Step 5: Commit(s)** `git commit -m "perf(win32): <cause> — <scenario> p95 <before> → <after> ms (RF)"`; final `git commit -m "test(windows): latency gates on ReleaseFast and Debug"`.

### Task 40: ConPTY latency mitigation (W5; mandatory when Task 36 shows ConPTY is the floor)

Windows Terminal does not use the inbox conhost for its tabs: it ships `conpty.dll` + `OpenConsole.exe` (the open-source conhost from the same repository) and, on new builds, can run ConPTY in passthrough mode, where VT output is forwarded instead of being re-rendered by conhost on its own timer. This task applies whichever variant Task 36 measured as best.

**Files:** Modify `src/pty.zig`, `src/os/windows.zig` (Windows-only: the product path for ConPTY selection, replacing Task 36's diagnostic overrides), the latency scripts (full-span gates), `docs/windows/latency-baseline.csv`; Create `dist/windows/conpty/README.md` (pinned version, SHA-256, licence, update procedure) and the build step that installs the bundled files next to `ghostty.exe` (`src/build/` Windows install step; single owner; only for the "bundled" outcome); `test/windows/e2e/conpty-variant.ps1`.

**Interfaces:**
- Produces:
  ```zig
  // src/pty.zig (Windows)
  pub const ConptyVariant = enum { inbox, inbox_passthrough, bundled, bundled_passthrough };
  pub fn chooseVariant(build_number: u32, bundled_present: bool, config: ConptySetting) ConptyVariant; // pure
  // config (core touch point only if the lead approves a user-facing switch): `windows-conpty = auto|inbox|bundled`
  ```
  Outcomes (decided by Task 36's data, recorded in SPEC §18.18 by the lead): (1) `inbox_passthrough` when the inbox `CreatePseudoConsole` of the supported Windows 11 builds accepts `PSEUDOCONSOLE_PASSTHROUGH_MODE` and it meets the thresholds — no new files shipped; (2) `bundled` (+ passthrough if supported by that OpenConsole) — `conpty.dll` and `OpenConsole.exe` from the pinned NuGet package installed next to `ghostty.exe` and loaded with `LOAD_LIBRARY_SEARCH_APPLICATION_DIR` only (no DLL search-path hijack); missing or failing files fall back to inbox with one warning; packaging in M6 picks the files up from the same install step; (3) neither helps → recorded, the gate stays on Ghostty-owned stages, owner informed.
  Every variant must keep M1 behaviour: Ctrl+C, resize (`resize-while-streaming`), `close-tree`/`tab-close-tree` semantics (OpenConsole hosts the console clients exactly like conhost), `typing-ru`/`typing-de-*` (input encoding), `vim-less`, `stream-integrity`.
- [ ] **Step 1: Failing test** `"windows pty: conpty variant choice"` (pure `chooseVariant`: bundled present + auto → bundled; absent → inbox; build below the passthrough minimum → no passthrough; `inbox` setting wins).
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dapp-runtime=none -Dtest-filter="windows pty"` → FAIL.
- [ ] **Step 3: Implement** the chosen outcome; `conpty-variant` scenario (order 153): state which variant is active (log line at surface creation) and run (a)/(b1) on it.
- [ ] **Step 4: Verify** full-span ReleaseFast gates of Task 36 (Debug recorded); `E2E -Milestone M1` PASS; `E2E -Only input-latency,tui-latency,output-latency,conpty-variant` PASS.
- [ ] **Step 5: Commit** `git commit -m "perf(windows): <variant> ConPTY — key echo p95 <before> → <after> ms (RF)"`.

### Task 38: File drag-and-drop from Explorer

Owner requirement (DECISIONS, 2026-10-26): dropping files/folders onto a surface inserts their paths, shell-quoted for the running shell and space-separated, as if pasted.

**Files:**
- Modify (replace stub): `src/apprt/win32/drop.zig`
- Modify (append): `pkg/win32/ole32.zig` (`RegisterDragDrop RevokeDragDrop ReleaseStgMedium`, `IDropTarget` (full slots: 3 IUnknown + DragEnter, DragOver, DragLeave, Drop = 7) as a Zig-implemented COM object, `IDataObject` (full slots = 12; typed `GetData QueryGetData`), `FORMATETC STGMEDIUM`, `CF_HDROP` (15), `TYMED_HGLOBAL`, `DVASPECT_CONTENT`, `DROPEFFECT_NONE DROPEFFECT_COPY`, `IID_IDropTarget`), `pkg/win32/shell32.zig` (`DragQueryFileW`, `DROPFILES`)
- Create: `test/windows/e2e/drop-files.ps1`, `test/windows/e2e/_drop.ps1` (OLE drag source helper)

**Decision — `IDropTarget`, not `WM_DROPFILES`:** OLE is already initialised on the UI thread (`App.init` calls `OleInitialize` for exactly this); `IDropTarget` gives `DragEnter/DragOver/DragLeave`, which the drop highlight and the per-surface target under the cursor need, and the copy cursor via `DROPEFFECT_COPY`; `WM_DROPFILES` only reports the final drop. One target per top-level window (`RegisterDragDrop(window.hwnd)` in `drop.register`, called by Task 6a): OLE walks up from the child under the cursor to the registered ancestor, and the registration survives tab re-parenting because it is on the window, not on the moved container. Known limit (as in Windows Terminal): an elevated Ghostty receives no drops from a non-elevated Explorer (UIPI); recorded in the changelog.

**Interfaces:**
- Consumes: Task 2 stub signatures, Task 6a (`register/revoke`, `Surface.shell_kind`), Task 6b (`drop.handle` in the hook chain), Task 11 oracle, `theme.palette` (highlight colour), messages `WM_GHOSTTY_DROP` (`+10`).
- Produces:
  ```zig
  pub const ShellKind = enum { msys, wsl, pwsh, cmd };
  pub fn shellKindFor(command: ?configpkg.Command) ShellKind;  // argv[0] basename, case-insensitive, ".exe" stripped:
      // bash/sh/zsh/fish/dash/ksh/busybox → msys (Git Bash/MSYS2); wsl → wsl; pwsh/powershell → pwsh; cmd → cmd;
      // unknown or null → cmd (owner decision 2026-10-26: unknown shells use cmd-style double quotes)
  pub fn msysPath(alloc: Allocator, win: []const u8) ![]u8;  // pure (owner decision 2026-10-26: Git Bash gets msys paths): C:\a\b → /c/a/b (drive
      // lower-cased); a "\\?\" prefix is dropped first; "\\?\UNC\srv\share\x" and UNC "\\srv\share\x" → //srv/share/x; every '\' → '/'
  pub fn wslPath(alloc: Allocator, win: []const u8) ![]u8;   // pure: C:\a\b → /mnt/c/a/b; UNC paths kept in msys form (//srv/share/x)
  pub fn quote(alloc: Allocator, kind: ShellKind, paths: []const []const u8) ![]u8;  // pure; joined with one space, no trailing space (macOS Ghostty behaviour)
      // msys/wsl: path converted first (msysPath/wslPath); a result made only of [A-Za-z0-9_./:@%+=,-] is left as is; otherwise single quotes, ' → '\''
      // pwsh:  a path made only of [A-Za-z0-9_.\\:/-] is left as is; otherwise single quotes, each ' (and U+2018, U+2019, U+201A, U+201B) doubled
      // cmd:   double quotes when the path has a space or any of &()[]{}^=;!'+,`~ or a non-ASCII char; '"' cannot occur in Windows paths; % is not escapable
      //        inside quotes in an interactive cmd and is left as is (documented, same as Windows Terminal)
  pub fn pathsFromDropFiles(alloc: Allocator, hdrop_bytes: []const u8) ![][]u8;  // pure parse of a DROPFILES block (fWide = 1: UTF-16, double-NUL list) → UTF-8;
      // any length (no MAX_PATH buffer; "\\?\" and UNC prefixes kept verbatim); unpaired surrogates → U+FFFD + log.warn
  pub fn register(window: *Window) void;     // allocates the IDropTarget object (refcounted; freed on the last Release after RevokeDragDrop)
  pub fn revoke(window: *Window) void;
  pub fn handle(window: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) ?LRESULT; // WM_GHOSTTY_DROP: lparam = *Payload { surface_id, text }
  // IDropTarget:
  //   DragEnter/DragOver: QueryGetData(CF_HDROP, TYMED_HGLOBAL) → DROPEFFECT_COPY else NONE; the surface under the point
  //     (ChildWindowFromPointEx down to a GhosttySurface, via Window.findSurface) gets the highlight; pointer over the strip → NONE
  //   DragLeave: hide the highlight
  //   Drop: GetData(CF_HDROP) → GlobalLock → pathsFromDropFiles → quote(surface.shell_kind) → ReleaseStgMedium → hide highlight →
  //     PostMessageW(window.hwnd, WM_GHOSTTY_DROP, 0, payload) and return at once (no core call inside the OLE callback, so Explorer's
  //     DoDragDrop loop is not blocked and the core is never re-entered from OLE)
  //   WM_GHOSTTY_DROP: findSurface(id) (gone → free and drop silently) → SetForegroundWindow + focus that surface →
  //     core_surface.textCallback(text): the same path as macOS Ghostty's drop (`ghostty_surface_text`): a paste, bracketed when the
  //     program enabled mode 2004 (readline in Git Bash, PSReadLine), never followed by Enter, no unsafe-paste prompt (a quoted path
  //     list has no newline)
  // Highlight: one owned layered popup per process (class GhosttyDropHighlight, WS_POPUP, WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW),
  //   a 2-px border (geom.scale(2, window.dpi)) in palette.text at alpha 0x99 around the target surface's screen rect, transparent inside;
  //   premultiplied 32bpp DIB written directly (no D2D), UpdateLayeredWindow; never takes focus or hit tests
  ```
  Multiple files and folders: one path each, in the order of the `DROPFILES` list. Text drops (`CF_UNICODETEXT` from a browser) are deferred to M3 (they need the unsafe-paste confirmation path); `DROPEFFECT_NONE` for them.
- [ ] **Step 1: Failing tests** in `drop.zig`:
  ```zig
  test "win32 drop: shell kind from the command" { // "C:\\Program Files\\Git\\bin\\bash.exe --login -i" → msys; "pwsh.exe -NoLogo" → pwsh; "C:\\WINDOWS\\system32\\cmd.exe" → cmd; "direct:wsl.exe ~" → wsl; null → cmd; "foo.exe" → cmd }
  test "win32 drop: msys and wsl paths and quoting" { // msys: C:\a b\c.txt → '/c/a b/c.txt'; D:\x\y.txt → /d/x/y.txt (unquoted); \\?\C:\long → /c/long; \\srv\share\f → //srv/share/f; it's → '.../it'\''s'; wsl: C:\a b → '/mnt/c/a b'; two paths joined by one space }
  test "win32 drop: pwsh quoting" { // C:\a b → 'C:\a b'; O'Brien → 'O''Brien'; U+2019 doubled; C:\plain\x.txt unquoted; $x → '$x' }
  test "win32 drop: cmd quoting" { // C:\a b → "C:\a b"; a&b → "a&b"; C:\plain\x.txt unquoted; Рабочая\ф.txt → quoted }
  test "win32 drop: DROPFILES parse" { // synthesized wide block with 3 paths incl. Cyrillic, a 300-char path, "\\\\?\\C:\\long" and a UNC path → exact UTF-8 strings }
  test "win32 drop: unpaired surrogate becomes U+FFFD" {}
  test "win32 drop: IDropTarget and IDataObject slot counts" { // 7 and 12 (oleidl.h / objidl.h of SDK 10.0.26100) }
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dtest-filter="win32 drop"` → FAIL.
- [ ] **Step 3: Implement**; `_drop.ps1` provides `Start-OleFileDrag -Files <string[]> -ToHwnd <h> -X -Y`: a small WinForms source window (in the scenario's PowerShell, STA) whose `MouseDown` calls `DoDragDrop` with a `DataObject` built by `SetFileDropList` (paths need not exist in Explorer; the helper creates them in the sandbox), driven by `Send-MouseDown/Move/Up` from `MouseInput.psm1` (real OLE path end to end; interactive only, SKIP otherwise). Scenario `drop-files` (order 470, milestone M2): sandbox files `a b.txt`, `it's & (x).txt`, `Рабочая папка\файл.txt`, a folder `dir with space`, and a 300-char path created with the `\\?\` prefix; for each shell config — Git Bash (SKIP without it), `pwsh` (SKIP without it), `cmd` — type the oracle prefix (`printf '%s\n' ` / `Write-Output ` / `for %f in (` … `) do @echo %~f`), drop all five onto the surface, check mid-drag that a visible `GhosttyDropHighlight` window of the pid covers the surface rect ±2 px, release, check that nothing ran yet (oracle file absent: the drop did not press Enter), then complete the line with `> %TEMP%\gt-drop.txt` + Enter → the file lists the five paths exactly (UTF-8 compare): in Git Bash as msys paths (`/c/…`, computed by the script with the same rules and cross-checked with `cygpath -u`), in pwsh and cmd as the original Windows paths; drop onto the second split of a two-split tab → the text lands in that split and it becomes focused; drop onto the tab strip → refused (`DROPEFFECT_NONE`, nothing typed).
- [ ] **Step 4: Verify** unit PASS; `E2E -Only drop-files,paste-confirm,typing-ru` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(win32): drop files from Explorer as shell-quoted paths (OLE IDropTarget)"`

### Task 39: Device loss with a resident process (W13)

Pre-flight 12 / M1 final review M6: once the tray keeps the process alive, a TDR or a driver update must not leave every later window black.

**Files:** Modify `src/renderer/d3d11/Device.zig` (shared device with a generation: `acquire()` returns the current healthy device; a renderer that sees `DXGI_ERROR_DEVICE_REMOVED/RESET` marks the generation lost; the next `acquire()` creates a fresh device; the lost one is released when its last renderer releases it), `src/renderer/D3D11.zig` (renderers acquire/release through it; a lost renderer stops drawing and logs once), `src/apprt/win32/App.zig` (fallback: when the device is lost and no window is left, the resident process quits instead of staying in the tray).

**Interfaces:**
- Produces:
  ```zig
  // Device.zig
  pub fn acquire(alloc: Allocator) !*Shared;     // refcounted; healthy generation or a new one
  pub fn release(shared: *Shared) void;          // last ref of a lost generation frees it
  pub fn markLost(shared: *Shared, reason: i32) void;
  pub fn isLost(shared: *const Shared) bool;
  pub fn anyLost() bool;                          // App fallback check
  ```
  Existing surfaces on a lost device stay blank until closed (full recovery with resource rebuild and the renderer-health bar is M3, SPEC §17); windows created after the loss render.
- [ ] **Step 1: Failing tests** (WARP)
  ```zig
  test "d3d11 device: acquire after markLost returns a new device" {}
  test "d3d11 device: the lost device is freed after its last release" { // refcount via a test hook }
  test "d3d11 device: renderers on the healthy device are unaffected" {}
  ```
- [ ] **Step 2: Run** `LOCK ZIG build test -j2 -Dapp-runtime=none -Dtest-filter="d3d11 device"` → FAIL.
- [ ] **Step 3: Implement**; a test-only env `GHOSTTY_D3D11_SIMULATE_DEVICE_LOST=<ms>` (Debug builds only) marks the device lost after that many ms; scenario `device-lost` (order 480, Debug only, SKIP on ReleaseFast): start, wait for the simulated loss, `new-window` op → the new window's dump shows the background colour (fresh device), log has exactly one "device lost" line.
- [ ] **Step 4: Verify** unit PASS; `E2E -Only device-lost,render,tray` → PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(d3d11): fresh shared device for new surfaces after device loss"`

### Task 33: M2 end-to-end run

**Files:** none planned; bug notes only (the lead files 34.n).

- [ ] **Step 1:** `LOCK ZIG build -j2`; `E2E -Milestone all -EvidenceDir %TEMP%\m2-evidence` (Debug). Then `LOCK ZIG build -j2 -Doptimize=ReleaseFast --prefix zig-out-rf`; `$env:GHOSTTY_E2E_EXE` = the RF exe; `E2E -Milestone all` again.
- [ ] **Step 2:** For every FAIL write a bug note (scenario, build, symptom, log excerpt, evidence path). `LOCK ZIG build test -j2 -Dtest-filter="win32 "` and `--build-file pkg/win32/build.zig` → record counts.
- [ ] **Step 3: Commit** only if scenario scripts needed fixes of their own: `git commit -m "test(windows): M2 e2e stabilisation"`.

### Task 34.n: Integration fix (template, one bug per task)

**Files:** exactly the files the bug note names (lead assigns; ≤ 3 parallel only with disjoint files).

- [ ] **Step 1:** Reproduce with the failing scenario; pure-logic bugs get a failing unit test first.
- [ ] **Step 2:** Fix; unit filter + scenario → PASS (SKIP noted when not interactive).
- [ ] **Step 3: Commit** `git commit -m "fix(win32): <bug summary>"`

### Task 35: RAM rows, screenshots, M2 acceptance

**Files:**
- Modify: `test/windows/measure-ram.ps1` (adds `windows`, `close-10`; `tabs`, `splits`, `zero-windows` exist since Task 14; all driven by `Invoke-GhosttyAction`, no keyboard input), `docs/windows/ram-baseline.csv`, `test/windows/README.md` (M2 runner, IPC module, `MouseInput.psm1`, scenario list, tray, tab-close, drop and latency behaviour), `test/windows/lib/Harness.psm1` (only if the README-documented helpers need fixes), `docs/windows/SPEC.md` §14 (steps are driven by the test IPC ops, not keybind `SendInput`; `zero-windows` row) and §17 (M2 marked done with the commit, any scope moved during execution) — pre-flight 24

**Interfaces:**
- Produces rows (ReleaseFast, hardware adapter): `tabs` = (1 window + 10 tabs − one-surface) / 10 per tab; `splits` = 10 splits in one tab, per split; `windows` = 5 windows, per extra window; `close-10` = open 10 tabs, close them, wait 30 s, private bytes vs before opening; `zero-windows` = resident in the tray with no window (recorded, not gated).
- [ ] **Step 1:** `LOCK ZIG build -j2 -Doptimize=ReleaseFast --prefix zig-out-rf`; run the five scenarios + `one-surface`.
- [ ] **Step 2: Gate** (SPEC §14): per tab/split ≤ +10 MB, per window ≤ +15 MB, close-10 within +10 % of the pre-open value. Over → the gate G1 decision applies (levers scheduled by the lead before this task); still over → DONE_WITH_CONCERNS with numbers and the owner decides (no silent pass).
- [ ] **Step 3: Screenshots:** one window with 3 tabs and 4 splits, dark and light, at 96/144/192 dpi (from `dpi-sim` evidence) + a maximized and a fullscreen capture + a drop highlight mid-drag (from `drop-files` evidence) → evidence dir; list paths in the report.
- [ ] **Step 4: ARM64:** `LOCK ZIG build -Dtarget=aarch64-windows-gnu -j2` → record (MSVC ARM64 in M6 CI).
- [ ] **Step 5: Exit checklist** (below) recorded in the report; commit `git commit -m "test(windows): M2 RAM rows, screenshots and acceptance record"`.

---

## M2 exit checklist

1. `LOCK ZIG build -j2` and ReleaseFast build succeed; `pkg/win32` tests pass; `-Dtest-filter="win32 "` passes 3× in a row; `-Dtest-filter="d3d11 "` and `"windows latency"` (`-Dapp-runtime=none`) and `config` pass; the M1 I2 Linux recipe and `-Demit-lib-vt` still build.
2. `win32 actions: every Action.Key is classified` green: 43 implemented, 25 deferred with milestone, 2 unsupported (counts as in Task 3; the test pins them).
3. `E2E -Milestone all` green on Debug and on ReleaseFast (M1 19 + M2 scenarios); SKIPs only for a non-interactive desktop and re-run by the owner.
4. Single instance: second launch exits 0 ≤ 2 s and the new window shows ≤ 1.5 s (ReleaseFast); two launches 50 ms apart end in one process; a launch with other arguments runs separately and ends with its last window; `+new-window` works; e2e instances never touched the owner's Ghostty (class isolation); an elevated instance uses the `-admin` pipe.
5. RAM rows `tabs`, `splits`, `windows`, `close-10` within SPEC §14 targets (gate G1 decision recorded); `zero-windows` recorded.
6. Screenshot set (Task 35 Step 3) inspected by the lead.
7. Latency (Tasks 36, 37, 40): every ReleaseFast gate of the Task 36 table met — key echo, TUI key navigation, TUI wheel scrolling (whole path ≤ 16 ms p95), wheel burst without backlog, output→present, Ghostty-owned stages ≤ 6 ms (or the lead's written adjustment with the stage table); Debug recorded; ConPTY variant decision recorded in SPEC §18.18; rows in `docs/windows/latency-baseline.csv` before and after.
8. Owner manual checklist (record PASS/FAIL per line): typing in the Debug and the ReleaseFast build feels immediate; wheel scrolling and navigation in `less`/`vim` (and the owner's usual TUIs, e.g. Claude Code) feel immediate; side-by-side with Windows Terminal on the same machine, typing and TUI scrolling are not noticeably slower (owner decision 2026-10-26); dragging files from Explorer into Git Bash, pwsh and cmd inserts correctly quoted paths and highlights the target pane; tray icon present after closing the last window, left click opens a window, menu New Window / Quit work, icon returns after restarting Explorer; `start cmd` from a tab survives closing that tab; dragging a tab to a window on a monitor with another scale renders it at that scale; snap layouts flyout on hovering maximize; Aero snap by dragging the caption to an edge; moving a window between monitors of different scale; Mica visible behind the strip with "Transparency effects" on and solid with it off; switching Windows light/dark in Settings repaints the strip and conditional themes (also with all windows closed, then opening one from the tray); Alt+Tab/taskbar titles follow the active tab; taskbar progress during a `winget`-style OSC 9;4 run; a "Run as administrator" Ghostty and a normal one run side by side without forwarding to each other.
9. Upstream rebase of `windows` onto upstream main (lead), M2 changelog for the owner (incl. known gaps: Git Bash cwd inheritance until M5 OSC 7 translation; no drops into an elevated Ghostty from a normal Explorer; tab context menu and tab tooltips in M3; existing windows stay blank after a GPU device loss until M3 recovery).

## M1 carry-over assignment

| M1 ledger / final-review item | Assigned |
|---|---|
| T14 last-window close always quits; `quit-after-last-window-closed` + delay unreachable; `startQuitTimer` doc | Task 28 |
| T14 local `RegGetValueW`; T26 local `EnumClipboardFormats` | Task 1 |
| T24 local `SystemParametersInfoW`/`GetClassNameW` in `mouse.zig`; T27 local kernel32 externs in `SwapChain.zig` | Task 37 (owns both files in W4; declarations from Task 1) |
| T14 `Window.create` errdefer pop not keyed by pointer; T21 dead child `SIZE_MINIMIZED` branch | Task 6a |
| T14 `terminate()` spin on failing `DestroyWindow`; T21 WM_CLOSE `wparam == 1` marker spoofable; `Surface.close` confirm bypasses `confirming_close` | Task 6b |
| T14 wakeup re-arm untested | Task 3 |
| T21 DPI scale applied after `SetWindowPos`; T29.2 `contentScaleCallback` before the coalesced size; final review M5 | Task 23 |
| T18 modal dialog re-enters the window procedure | Task 27 (+ posted-message rule, Global Constraints) |
| Final review I1 quit without confirmation | done in M1 (`WM_GHOSTTY_QUIT` + `QuitGate`); Task 27 swaps the dialog, Task 28's tray Quit reuses it |
| T24 duplicated surface class name; `refreshCursor` skips a captured surface | Task 16 |
| T22 dump readback + file I/O under the shared context lock (final review M4, part 1) | Task 4 |
| T27 `waitForSlot` bool drift; `draw_mutex` held during the slot wait (final review M4, part 2) | Task 37 |
| Final review M6 device loss is terminal | Task 39 (new surfaces get a fresh device; full recovery M3) |
| Final review M1 process handle never closed | done (538506c09); Task 29 keeps the call on the new kill path |
| T29.4 `formatEntry` 4096-byte fixed buffer | Task 15 |
| T28 all-SKIP run exits 0 | Task 4 |
| T30 CSV commit stamp, CRLF, README double blank line, `AdapterDesc` layout assert | Task 4 |
| T5 SharedDeps links Win32 libs for lib-vt consumers | Task 1 |
| T19 owner question (console processes killed on tab close) | answered by the owner (Windows Terminal semantics) → Task 29 |
| T13 `systemExists` OOB, T19 pid-reuse race in `killTree` ("fix in final wave") | done in M1 |
| T23 keyboard, T26 clipboard, T12 font, T11/T20 shader, T16 logging, T8/T9 renderer minors | stay deferred (M3 input/clipboard/font/shader polish, M5 logging) |

## Self-review notes

- Spec coverage (SPEC §17 M2 as amended): custom frame + Mica + snap (12, 17, 18), tabs incl. reorder/rename (10, 13, 19), splits (9, 14, 16), multi-window (21), placement toggles (22), DPI (23), theme/colour scheme/config reload (15), scrollbar (25), bell + taskbar progress (26), resize overlay (24), TaskDialog confirmations (27), tray + last-window lifecycle (28), tab-close process semantics (29), tab tear-off/re-dock with re-parent-safe swap chains (30, 31, 32), IPC + single instance + `performIpc` (5, 8, 11, 20), action coverage (3), file drop (38), latency incl. TUI scrolling and ConPTY (36, 37, 40), device loss with a resident process (39), RAM/screenshots (14 probe, G1, 35). Deferred by design: unfocused-split dimming and `bell-features=border` (M3 DComp overlays), readonly badge (M3), tab context menu and tab tooltips (M3), text drops (M3), full device-loss recovery (M3), everything in Task 3's deferred list.
- Every wave re-checked against the `Files:` lists: ≤ 3 tasks, no file in two tasks of one wave; each multi-owner file follows its chain in the hot-file list. W1: 36 renderer + `Surface.zig`/`keyboard.zig`/`mouse.zig` + `Exec.zig`/`pty.zig`/`os/windows.zig`, 2 stubs + `win32.zig`/`dialogs.zig`, 3 `App.zig` + actions. W2: 1 `pkg/win32` + `util.zig`/`clipboard.zig`/`SharedDeps.zig`, 5 protocol/Overrides, 6a model files. W3: 4 scripts + `Frame.zig`/`D3D11.zig`/`Device.zig`, 6b model files, 8 IPC transport. W4: 11 `App.zig`/`ops.zig`, 37 renderer/`keyboard.zig`/`mouse.zig`/`Exec.zig`/latency scripts, 7 `pkg/win32` main/build. W5: 9, 10 pure files, 40 `pty.zig`/`os/windows.zig`/latency scripts. W6: 12 spike, 13 `Window.zig`/`tab_actions`/`window_actions`, 14 `Tab.zig`/`split_actions`/RAM files. W7: 15 theme/`app_actions`/`uxtheme`/`shell32`/`command.zig`, 30 `D3D11.zig`/`SwapChain.zig`/`Surface.zig`, 29 `Command.zig`/`Exec.zig`/`_common.ps1`. W8: 17 `frame.zig`/`MouseInput`, 18 `Chrome.zig`/`App.zig`/`uxtheme`, 25 `scrollbar.zig`/`Surface.zig`/`surface_actions`. W9: 19 `strip_input`/`window_actions`/`comctl32`/`MouseInput`, 20 `App.zig`/`instance.zig`/`Config.zig`, 21 `Window.zig`/`app_actions`/`tab_actions`. W10: 22 `placement`/`window_actions`, 23 `Window.zig`/`Surface.zig`/`dpi.zig`, 16 `Tab.zig`/`mouse.zig`. W11: 26 `bell`/`taskbar`/`window_actions`/`shell32`/`winmm`/`ole32`, 27 `dialogs`/`App.zig`/`comctl32`, 24 `resize_overlay`. W12: 28 `App.zig`/`Config.zig`/`app_actions`/`ops.zig`/`shell32`, 31 `tab_drag`/`drag_ghost`. W13: 32 `strip_input`/`Window.zig`/`Tab.zig`, 38 `drop.zig`/`ole32`/`shell32`, 39 `Device.zig`/`D3D11.zig`/`App.zig`. Stubs created in W1 carry every cross-task signature so later waves never edit another task's file.
- Type names used across tasks: `TabStrip.Layout/Metrics/Part/Mode/Drag`, `SplitLayout.Layout(Tree)`, `geom.Rect`, `theme.Palette/Color`, `frame.State/Decorations/Size`, `placement.State`, `scrollbar.State`, `taskbar.State`, `resize_overlay.State`, `drop.ShellKind`, `Overrides`, `protocol.Request/Response/Code`, `Server.Pending`, `client.Error`, `instance.ForwardResult`, `windows_latency.Sample`, `Window/Tab/Surface.CreateOptions`, `dialogs.CloseKind` — defined once (Tasks 2, 5, 6a, 8, 9, 10, 20, 36, 40) and only consumed elsewhere.

## Pre-flight dispositions

Review: `docs/windows/plans/M2-preflight-review.md` (2 BLOCKER, 14 IMPORTANT, 13 MINOR). Result: 2/2 BLOCKER applied; 14/14 IMPORTANT applied (15 with one deviation, stated); 13/13 MINOR applied (27 as "record").

| # | Sev. | Disposition |
|---|---|---|
| 1 | BLOCKER | Applied: `messages.zig` keeps M1 `+1..+4` (`+4` = `WM_GHOSTTY_QUIT`), then `+5` IPC … `+9` tray, `+10` drop; `WM_GHOSTTY_QUIT_CONFIRM` dropped; uniqueness test compares against `App`/`clipboard` constants; Task 3 switches `App.zig`, Task 2 does not touch it; timer-id table added. |
| 2 | BLOCKER | Applied: `-admin` pipe suffix when elevated, `S:(ML;;NW;;;HI)` label, server and client check the peer's elevation and user (Tasks 5, 8); commands never forwarded (`forwardable` = `--working-directory=` only) and the op handler refuses `-e`/`--command=` anyway (Task 11); tests for the marker and a mismatched peer. |
| 3 | IMPORTANT | Applied: (a) Task 6a/6b verify with `e2e-m1.ps1`; (b) `chrome-paint` moved to Task 19; (c) reorder adopted in substance — Task 30 lands (W7) before Task 21 (W9) and Task 32 (W13), Task 16 after Task 19, Task 28 after Tasks 20/21/27; wave numbers differ from the review because W1 now starts with Task 36, Task 6 is split and Tasks 37/40 were added; (d) `bell.decorateTitle` stub (Task 2) called by Task 13; (e) `strip_input.handle` consumes `WM_GHOSTTY_TITLE_EDIT_DONE`; (f) W7 row lists 15 for 17. |
| 4 | IMPORTANT | Applied: M1's quit path is the only one (Tasks 3, 21, 27, 28); Task 28's Config change is one doc sentence and is no longer a code touch point; 19 M1 scenarios everywhere; process-handle leak noted as fixed. |
| 5 | IMPORTANT | Applied: the pipe is claimed in `App.init` before any window (Task 11), `AddressInUse` → forward decision (Task 20); non-owners get no tray and quit after their last window (`lastWindowAction(…, pipe_owner)`, Task 28); `single-instance` e2e covers two launches 50 ms apart and a `--font-size` launch. |
| 6 | IMPORTANT | Applied: `deadline_ms` in every request, server refuses expired requests, client timeout > deadline; `PostMessageW` failure answers code 1 at once (Tasks 5, 8, 11). |
| 7 | IMPORTANT | Applied: client checks the server's user and elevation before writing, opens with `SECURITY_SQOS_PRESENT|SECURITY_IDENTIFICATION`; squat → `NotOurServer` + warn; relative `--working-directory=` absolutized (Task 20); `GHOSTTY_WIN32_TEST_IPC` removed from the process environment (Task 11). |
| 8 | IMPORTANT | Applied the second option (no owner sign-off needed, it matches DECISIONS): `forwardable` = only `--working-directory=`; SPEC §18.6 amended. |
| 9 | IMPORTANT | Applied: `frame.nonClientSize` stub (Task 2), routed by Task 6a, made real by Task 17; size tests in Tasks 6a and 22 (`initial_size` in client/server/none, min track size with the strip). |
| 10 | IMPORTANT | Applied: spike checks (a) ghost caption buttons, (b) maximized under Mica, (c) `SetParent` of a presenting swap chain; `hwnd` variant dropped; Task 30 becomes defensive if (c) holds. |
| 11 | IMPORTANT | Applied: RAM probe in Task 14 (`measure-ram.ps1` rows through IPC actions, incl. `zero-windows`), lead gate G1 before W7 with the named levers and an owner escalation instead of a silent DONE_WITH_CONCERNS. |
| 12 | IMPORTANT | Applied: new Task 39 (fresh shared device for new surfaces, lost device freed with its last renderer, resident process quits when the device is lost and no window is left). |
| 13 | IMPORTANT | Applied: `Window.beginTeardown` / hide-before-destroy in Task 6b; `split-many` closes 16 panes with 4 streaming (invisible ≤ 300 ms, other window answers `WM_NULL` ≤ 100 ms). |
| 14 | IMPORTANT | Applied: one Harness config writer that always sets `class`, Global Constraint "never start `ghostty.exe` outside the harness", `Assert-FreeRam 2.5` for scenarios with > 4 surfaces (header `surfaces=N`), Debug runs of those take the test-lock. |
| 15 | IMPORTANT | Applied with one deviation: Task 6 split into 6a/6b; mouse helpers moved to `MouseInput.psm1` (Tasks 17/19); tray, taskbar, task dialog, buffered paint, `SetWindowTheme`, `ShellExecuteW`, winmm and OLE bindings moved to their tasks; the `mouse.zig`/`SwapChain.zig` extern moves go to Task 37 (Task 36 owns those files in W1, before Task 1 lands in W2). Deviation: `user32`/`kernel32`/`advapi32`/`dwmapi`/`gdi32` stay complete in Task 1, because under strictly disjoint waves no later task may edit those shared files (a late need is a lead one-line commit between waves). |
| 16 | IMPORTANT | Applied: `window.dpi` is the single source (Global Constraint, Tasks 6a, 11, 23); `dpi-sim` opens a new tab and split after the change and checks their scale; `GetDpiForWindow` audit in Task 23. |
| 17 | MINOR | Applied: mutex-guarded outstanding list in `stop()`, 64 KiB M2 request cap, the listed bindings added to Task 1. |
| 18 | MINOR | Applied in Task 28 (menu foreground/`WM_NULL`, message filter when elevated, resource icon, end-session handling); the `GhosttyWindow` class icon in Task 21 (owner of `Window.zig` in that wave). |
| 19 | MINOR | Applied: `theme.settingChanged` used by the tray window (Task 28); high contrast disables Mica and uses system colours (Task 15). |
| 20 | MINOR | Applied: window lookup by `EnumWindows` class + pid (Task 4); down/move/up mouse helpers (Task 19, used by Tasks 32 and 38); fixed placement of window A in `tab-drag`. |
| 21 | MINOR | Applied in Task 30: recreation under the context lock with `ClearState` + `Flush` + all back-buffer references released, waitable closed, pacing reset; `Surface.window` off-thread read audit. |
| 22 | MINOR | Applied, re-homed: the pacing counter and the `draw_mutex` fix go to Task 37 (it owns `D3D11.zig`/`SwapChain.zig` three waves before Task 30 and is about pacing anyway); `split-many` pacing check in Task 14; `formatEntry` buffer in Task 15. |
| 23 | MINOR | Applied: see 8, 10, 15; Task 30 kept but conditional on spike (c). |
| 24 | MINOR | Applied: SPEC §14 (IPC-driven steps, `zero-windows`), §7.2 (`actions.zig` holds the coverage test) and §12.1 (external-mode pipe name follows §18.5) updated in this revision; Task 35 re-checks §14/§17. |
| 25 | MINOR | Applied in Task 17 (1-px top extension in the opaque fallback; NC and client hover mutually exclusive). |
| 26 | MINOR | Applied: Task 1 Step 4 builds `-Demit-lib-vt` and the Linux recipe. |
| 27 | MINOR | Applied as "record": the Git Bash cwd-inheritance gap is stated in Task 13 and the M2 changelog; the msys→Windows path mapping stays with OSC 7 translation in M5 (doing half of it in M2 would split one feature across milestones). |
| 28 | MINOR | Applied: Task 29 moved to W7, the first wave after tabs (Task 13, W6) that its `tab-close-tree` scenario needs. |
| 29 | MINOR | Applied: tab context menu and full-title tooltip listed as deferred to M3 (Task 19, changelog). |

## Owner update (2026-10-26, after revision 2's first draft)

The owner reported noticeable typing lag in the ReleaseFast build too, and high lag when scrolling with the mouse wheel and navigating in TUI apps. Applied: Task 36 is the first task of M2 (W1; Task 1 moved to W2 and the present-target id seam moved from Task 2 to Task 36 to keep W1 file-disjoint); it measures key echo, TUI key navigation and wheel scrolling (`less`, `vim`), wheel bursts and output→present, instruments the input path (`WM_KEYDOWN`/`WM_MOUSEWHEEL` → core → pty write) and the output path (ConPTY read → parse → renderer wakeup → frame-slot wait → `Present`), and compares ConPTY variants (inbox flags incl. `PSEUDOCONSOLE_PASSTHROUGH_MODE`, bundled `conpty.dll` + `OpenConsole.exe`); per-scenario thresholds are in its table. Task 37 fixes causes inside Ghostty (frame-slot wait, wheel coalescing, `WM_CHAR` draining, 2 KiB slicing + `yieldToDemand`, Debug costs); new Task 40 (W5) applies the ConPTY mitigation when ConPTY is the floor. Task 29 moved to W7 as a side effect of the re-layout.

Owner answers (DECISIONS, 2026-10-26, applied): drops into Git Bash insert msys paths (`'/c/Users/…'`), unknown shells get cmd-style double quotes (Task 38); the latency gate is the whole path ≤ 16 ms p95 on ReleaseFast with Ghostty-owned stages ≤ 6 ms, ConPTY passthrough / bundled OpenConsole when ConPTY is the floor, plus a hands-on comparison with Windows Terminal; Debug may stay slower (Tasks 36, 37, 40).

## Open owner questions

None open. Recorded defaults the owner may still overturn: TUI wheel-burst settle ≤ 50 ms and idle output→present ≤ 8 ms on ReleaseFast (Task 36 table); a user-facing `windows-conpty = auto|inbox|bundled` option is added only if Task 40 ships the bundled variant and the lead approves it.
