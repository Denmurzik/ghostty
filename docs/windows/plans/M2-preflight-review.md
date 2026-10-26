# M2 pre-flight review

Plan: `docs/windows/plans/M2-tabs-splits-windows.md` (35 tasks / 14 waves). Read-only review against DECISIONS (incl. owner
decisions 2026-10-26), SPEC §5/§7/§12/§14/§17/§18, the M1 ledger + final review, and the M1 code at `87f9325ba` (no builds/GUI runs).

Totals: **2 BLOCKER, 14 IMPORTANT, 13 MINOR.**

## BLOCKER

**1. Private message id `WM_APP+4` collides on `msg_hwnd`; the fix cannot land in Task 2 (Tasks 2, 3, 11, 21).**
M1 fix wave (4f4816248) put `WM_GHOSTTY_QUIT = WM_APP+4` on the message-only window (`src/apprt/win32/App.zig:31`,
handled at `:244`). The plan puts `WM_GHOSTTY_IPC = +4` on the same window, so Task 11's first forwarded `new-window` would
run the quit flow. Task 2 cannot edit `App.zig` either: Task 3 owns it in W1. Other ids checked: `+1` wakeup (msg window),
`+2` clipboard read (posted to the surface HWND, `clipboard.zig:29`), `+3` quit-timer constant (unused, the timer is
`WM_TIMER` id 1), `WM_APP+7` in `pkg/win32/test_user32.zig:40` (own test window). None of these collide.
Fix: `messages.zig` keeps `+1..+4` as M1 (`+4` = `WM_GHOSTTY_QUIT`, msg window), then `+5` IPC, `+6` CLOSE_SURFACE,
`+7` CLOSE_TAB, `+8` TITLE_EDIT_DONE, `+9` TRAY, `+10..+15` reserved. Drop `WM_GHOSTTY_QUIT_CONFIRM` (see 4). The
uniqueness test also imports `App.WM_GHOSTTY_*` and `clipboard.WM_GHOSTTY_CLIPBOARD_READ`. Task 3 (W1 owner of `App.zig`)
switches App to `messages.zig`; Task 2 does not touch `App.zig`. Add a timer-id table to `messages.zig` (per HWND class).

**2. The forwarding pipe is a UAC bypass when Ghostty runs elevated (Tasks 5, 8, 11, 20).**
The DACL `D:P(A;;GA;;;<sid>)` grants the same user SID at every integrity level, and the pipe name ignores elevation. A
medium-IL process can send `new-window --command=<anything>`, which is forwardable under ruling 6, or the test op
`action text:…`, to an elevated Ghostty, which then runs the command elevated. Fix: add `-admin` to the pipe name when
`TokenElevation` is set; an elevated server adds the label `S:(ML;;NW;;;HI)` to its SDDL; the server rejects a client whose
token elevation differs (`GetNamedPipeClientProcessId` → `OpenProcessToken` → `TokenElevation`). Drop `--command=` from
`forwardable` (see 8). Add tests: the pipe name has the elevation marker; a mismatched client gets `code 1`.

## IMPORTANT

**3. Wave and dependency errors (Tasks 6, 16, 17, 18, 19, 21, 24, 26, 30).**
(a) Task 6 Step 4 runs `E2E` (`e2e.ps1`), which Task 4 creates in the same wave (W2). Task 6 should use `e2e-m1.ps1`.
(b) Task 18 (W6) runs `chrome-paint` and `frame-hittest`, but until Task 17 lands in the same wave, `frame.stripMode` is the
stub `.hidden`. The strip is then 0 px high, so there is nothing to paint or hover. Move `chrome-paint` to Task 19 (W7).
(c) Task 21 (W7) re-parents surfaces (`move_tab_to_new_window` → `SetParent`) three waves before Task 30 makes that safe.
Reorder: **W6 = 17, 18, 30; W8 = 22, 23, 16; W10 = 28, 24, 31.** The file sets stay disjoint, and the hot-file chains
become `Surface.zig` 2→6→30→23→25, `D3D11.zig` 2→4→30, `Tab.zig` 6→14→16→32, `mouse.zig` 1→16.
(d) Task 26's bell caption prefix needs `Window.refreshTitle`, but `Window.zig` is not one of its files. Task 2 should stub
`bell.decorateTitle(alloc, title, tab) []u8` and Task 13 should call it.
(e) Task 19's `WM_GHOSTTY_TITLE_EDIT_DONE` needs a handler, but `Window.zig` belongs to Task 21 in W7. Say that
`strip_input.handle` consumes it.
(f) The W6 table row for Task 17 omits Task 15, which it consumes for `palette.mica`.

**4. Parts of the plan are stale against M1 code (Tasks 3, 4, 21, 27, 28, exit checklist).**
Quit confirmation already exists: a message on the msg window plus `QuitGate` (`App.zig:52-70, 266-283`). Task 3's "21 adds
confirm" and Task 21's `WM_GHOSTTY_QUIT_CONFIRM` in `Window.zig` would build a second path. Keep M1's: Task 21 only routes
to it, and Task 27 swaps `dialogs.confirm` for `confirmCloseKind(.app)`. The tray Quit uses the same path.
`quit-after-last-window-closed` already defaults to `false` on Windows (`Config.zig:2645`: `os == .linux`), so Task 28's
"core touch point" reduces to one doc sentence. Remove it from the Global Constraints list; the only bug is
`windowDestroyed` always quitting. There are now 19 M1 scenarios (`stream-integrity` from Task 30b), not 18 (Task 4 Step 4,
exit checklist 3). The process-handle leak is already fixed (538506c09).

**5. The single-instance claim races, and processes that do not serve the pipe stay alive forever (Tasks 11, 20, 28).**
The forward check runs in `App.init`, but the server starts only after the first window is up (about 1 s). Two quick
launches (a double-click, or Explorer "Open here" twice) therefore both run standalone. The loser hits `AddressInUse` and
keeps running with no pipe. With the Windows default `quit-after-last-window-closed = false`, that process stays in the tray
for good. So does every `ghostty --font-size=20` launch: `-e` forces quit-after-last to true (`Config.zig:5034`), but plain
arguments do not. Fix: claim the name first, with `CreateNamedPipeW(FIRST_PIPE_INSTANCE)` in `App.init`. Success makes
this process the primary, and clients queue in the pipe. `AddressInUse` means forward. A process that does not own the pipe
gets no tray icon and quits after its last window. Add these cases to `single-instance` e2e: two launches 50 ms apart, and
a `--font-size` launch that ends after its window is closed.

**6. A client timeout can open the window twice (Tasks 8, 11, 20).**
`forwardNewWindow` times out after 1000 ms and the launch falls back to standalone. The server still holds the request and
runs it later, so the user gets two windows in two processes. A busy UI thread can cause this: a Debug first-window create,
or a burst of three launches. Fix: the request carries `deadline` (`GetTickCount64` ms; the clock is shared on one machine),
the server answers `code 1` and does nothing once that deadline has passed, and the client's timeout is longer than the
deadline. Also: if `PostMessageW` to the msg window fails (queue full), answer `code 1` at once. Otherwise the IPC thread
waits on `done` forever and every later client times out.

**7. The client does not check who owns the pipe (Tasks 8, 11, 20).**
Pipe names are global across users and sessions, and SIDs are not secret. Another user can pre-create
`ghostty-<victim SID>-…`. The victim's Ghostty then runs serverless (`AddressInUse`), and the victim's launches send their
arguments and cwd to the squatter. Fix: before writing, the client checks the owner with `GetNamedPipeServerProcessId` →
`OpenProcess` → token user SID == own SID, plus the same elevation. It opens the pipe with
`SECURITY_SQOS_PRESENT|SECURITY_IDENTIFICATION`. The server logs `warn` (not `info`) on `AddressInUse` when the
owner check fails. Also: absolutize a relative `--working-directory=` in the forwarding process (Task 20; `new_window.zig`
already does this), and strip `GHOSTTY_WIN32_TEST_IPC` from the child env so nested launches do not inherit test ops (Task 11).

**8. Ruling 6 contradicts DECISIONS (Tasks 5, 20; SPEC §18.6).**
The owner wrote: "a launch with arguments (`--font-size=…`, `-e …`) starts a separate process". Ruling 6 also forwards
`--title=`, `--command=` and `--shell-integration=`. Either get the owner's sign-off, or limit `forwardable` to
`--working-directory=`, which Explorer "Open Ghostty here" needs. The second option also closes most of blocker 2.

**9. The custom frame breaks M1's window-size math, and no task owns the fix (Tasks 6, 17, 22).**
`Window.frameSize()` (`Window.zig:189`) uses `AdjustWindowRectExForDpi(WS_OVERLAPPEDWINDOW)`. Once `WM_NCCALCSIZE` removes
the caption and a strip sits inside the client area, `initial_size` (window-width/height), `size_limit` (`WM_GETMINMAXINFO`),
`resize_window` and `reset_window_size` are all off by (caption − strip) px. Fix: Task 17 exports
`frame.nonClientSize(window) {w,h}` = frame insets + strip height. The Task 2 stub returns the M1 value, and Task 6 routes
`frameSize` through it. Test: `initial_size` 800×600 gives a content rect of 800×600 in client, server and none modes, and
the minimum track size includes the strip.

**10. The spike leaves out the riskiest questions (Task 12, also Tasks 17, 30).**
Add: (a) no DWM-drawn "ghost" caption buttons in the extended frame. `WS_CAPTION` is kept and the caption removed, so sample
the top-right corner with our buttons not painted. (b) Maximized under Mica: insets right, no overflow onto another monitor.
(c) `SetParent` of a child whose flip-model swap chain is presenting into a second top-level window, with no recreation.
If it keeps rendering, Task 30 becomes a defensive fallback; if not, the spike records what recreation needs (see 21).
Drop the `hwnd` variant: an `ID2D1HwndRenderTarget` on a `WS_CLIPCHILDREN` top-level window gives no per-pixel alpha over
the extended frame, so it cannot win, and dropping it saves a third of the spike.

**11. RAM is first measured in W14, too late to change the per-surface design (Tasks 14, 35; exit checklist 5).**
Each surface has its own child HWND and swap chain. Hidden tabs keep full-size back buffers. Every renderer has its own atlas
textures and three threads. M1 is already at 105.8 MB against the 80 MB v1 target. The plan says "no tuning here", but exit
item 5 requires being within target, so there is no route to exit if the numbers are over. Fix: add a ReleaseFast RAM probe
at the end of Task 14 (`tabs` and `splits` rows through IPC actions, about 5 min). Name the levers now: `ResizeBuffers` to
8×8 or release the swap chain while a tab is occluded, and share atlas textures. Add a decision point for the lead before W8.
Also record a "0 windows (tray resident)" row.

**12. Device loss is terminal, and the tray keeps the process resident (missing; M1 final review M6).**
After a TDR or a driver update from Windows Update, every window opened later (from the tray or by the next launch) shares
the dead device and stays black until the user quits from the tray. This is not in the carry-over table. Minimum for M2:
when the shared device reports `DeviceLost`, new surfaces create a fresh device, and the old one is dropped when its last
renderer exits. Fallback: the resident process quits once the device is lost and no window is left. Assign this to Task 28
or a new task in W10.

**13. Closing many surfaces freezes the UI (Tasks 6, 14, 21).**
`Surface.destroy` joins the render and IO threads on the UI thread, one surface at a time. Closing a 16-pane window,
`close_all_windows` or `close-10` can freeze for seconds (Debug `close-while-streaming` was 0.5–0.7 s per surface).
Fix: `SW_HIDE` the window or tab container before tearing it down, so the close is instant to the eye. Add to `split-many`:
close the 16-pane window with 4 panes streaming; the window is invisible within 300 ms and `WM_NULL` to another window is
answered within 100 ms throughout.

**14. Owner-machine safety and RAM in GUI runs (Tasks 4, 12, 20, 33).**
Once Task 20 lands, any agent-started `ghostty.exe` without a unique class shares the Debug pipe `…-ghostty-debug` with the
owner's Debug Ghostty. That covers `test/windows/launch.ps1`, the capture flows, the spike, and manual `zig-out\bin` runs. The
owner's launches would then open inside agent processes that the agent later kills. Fix: Task 4 writes `class` in one
Harness config writer used by every script, and a Global Constraint forbids starting `ghostty.exe` outside the harness.
Separately, GUI e2e holds only the GUI lock, not the test-lock. Debug `split-many` or `windows-multi` (16 surfaces plus 16
OpenConsole processes) running next to another agent's `-j2` build can exhaust the 2–5 GB that is free. Scenarios with more
than 4 surfaces should check free RAM ≥ 2.5 GB first (SKIP otherwise) or take the test-lock.

**15. Tasks well over about 400 changed lines (Tasks 1, 6, 11; borderline 3, 8, 13, 18, 19, 28, 32).**
Task 1 declares about 150 items across 13 files, many first used in W9–W11. Limit it to what W2–W4 need (pipes, advapi32,
NC and frame user32, dwmapi). Tray, menu, TaskDialog, buffered paint, layered window and winmm bindings move to Tasks
18/26/27/28/31 under the existing append rule. Task 6 (about 900 lines: Tab, Window rewrite, Surface refcount, close flow,
hook chain, App) splits into 6a (model, single tab, refcount, `windowFor`) and 6b (close flow, `CloseKind`, hook dispatch).
In Task 11, move the `Send-Mouse*` helpers to the first task that uses them (16/19).

**16. Simulated DPI is not consistent (Tasks 11, 23).**
The `dpi` op calls `applyDpi(dpi, null)`, but `Surface.zig:136/414`, `Window.zig:202` (`frameSize`), `frameInsets` and Chrome
read the real DPI. `dpi-sim` can pass while a real monitor move fails, and a tab created after a simulated change mixes
scales. Rule: `window.dpi` is the single source, and only `WM_DPICHANGED` and window creation read the system value.
`dpi-sim` should also open a new tab and a split after the change and check their `scale`.

## MINOR

**17. IPC server details (Task 8).** `stop()` needs a mutex-guarded list of outstanding `Pending` items to complete the
queued ones. Cap M2 requests at 64 KiB until M4 needs 16 MiB, because JSON is parsed on the UI thread.
`AllowSetForegroundWindow`, `GetNamedPipeClientProcessId`, `GetSystemMetricsForDpi`, `WindowFromPoint`,
`ChangeWindowMessageFilterEx` and `MessageBeep` are missing from Task 1's list.

**18. Tray (Task 28).** Call `SetForegroundWindow(tray)` before `TrackPopupMenuEx` and post `WM_NULL` after it (the classic
menu-dismiss bug). When elevated, call `ChangeWindowMessageFilterEx` for "TaskbarCreated" and "TaskbarButtonCreated". The
icon is resource id 1 (`dist/windows/ghostty.rc`); use it for the `GhosttyWindow` class too (`Window.zig:47` loads
`IDI_APPLICATION`; DECISIONS asks for the original icon). Handle `WM_QUERYENDSESSION`/`WM_ENDSESSION` on the tray window:
no confirmation dialogs at logoff, quit cleanly.

**19. Theme (Task 15).** `system_dark` is cached. A message-only window gets no `WM_SETTINGCHANGE` broadcast, so with 0 windows
(tray resident) a light/dark switch is missed. Route the tray window's `WM_SETTINGCHANGE` to `theme`, or re-read on the first
window. The palette ignores `SPI_GETHIGHCONTRAST`.

**20. Harness (Tasks 4, 32).** `Start-E2eGhostty` picks `$proc.MainWindowHandle` (`_common.ps1:404`), which is ambiguous
with several `GhosttyWindow`s and the visible, unowned drag ghost. Find the window with EnumWindows by class + pid, or via
the state oracle. `Send-MouseDrag` is synchronous, so the check that the ghost is visible mid-drag cannot run: add
`-OnStep {}` or split it into down/move/up. `tab-drag` should first place window A at a fixed position in the work area,
because "250 px below its bottom" can be off-screen or on the taskbar.

**21. Recreating the swap chain on re-parent (Task 30), if it is kept.** Recreate under the context lock: `ClearState` +
`Flush` + release every back-buffer RTV before calling `CreateSwapChainForHwnd` on the same HWND. Deferred destruction
otherwise gives `E_ACCESSDENIED`. Close the old waitable and reset pacing. Audit reads of `Surface.window` off the UI thread
(`rtApp()`), because `setWindow` rewrites it during the re-parent.

**22. Unassigned M1 renderer carry-overs (final review M4).** `waitForSlot` bool drift should become a pending counter, and
`draw_mutex` is held during the slot wait. Assign both to Task 30, which owns that file, and add a pacing check to
`split-many` (16 panes, 4 streaming). Also unassigned: the 4096-byte `formatEntry` FBA hit by reload and `+show-config`
(Task 15).

**23. Over-built.** The spike's `hwnd` variant (see 10); forwarding `--title=`, `--command=` and `--shell-integration=` (see 8);
front-loaded bindings (see 15); Task 30 itself, if spike (c) shows `SetParent` keeps working.

**24. SPEC drift (Task 35).** §14 says RAM steps are "driven by keybind SendInput", while Task 35 uses IPC actions, so §14
needs updating as well as §17. §7.2 names `actions_test.zig`. §12.1's external-mode pipe name (M5) has to follow ruling 5.

**25. Frame polish (Task 17).** In the opaque fallback the frame is extended by 0 px, so restored windows lose the DWM top
border; extend 1 px in that mode. `frame.hover` (NC) and `strip_input.hover` (client) can both be set when the pointer moves
between buttons and tabs; clear the other one on every update.

**26. Build check (Task 1).** The `SharedDeps.zig` link-list change can break lib-vt or non-Windows builds. Step 4 should also
run `zig build -Demit-lib-vt` and the M1 I2 Linux recipe (`-Dtarget=x86_64-linux-gnu -Dapp-runtime=none`).

**27. Known UX gap to record.** Tab and split cwd inheritance does not work from Git Bash, the default shell. OSC 7 reports
`/c/…`, the access check at `Exec.zig:1026` fails, and the path is ignored. SPEC defers OSC 7 translation to M5. Either note
this in the M2 changelog or move a pure msys→Win path mapping into Task 13.

**28. Task 29 could land much earlier.** Its core change does not depend on the GUI; only its e2e uses tabs. Until W11, every
close still kills `start cmd` windows, which goes against the owner decision. The `_common.ps1` chain (4→29→35) allows W5.

**29. Missing parity items to defer explicitly.** A tab context menu (close / close others / rename / move to new window) and a
tooltip with the full title on trimmed tabs. Windows Terminal and GTK both have them. Add them to Task 19 or list them as
deferred.
