# M1 final whole-branch review

Range `cec8b92f1..e96668c19` (68 commits, 135 files, +23243/-403). Reviewer: final-review-m1 (opus). Read-only review, no builds or GUI runs; acceptance evidence (e2e 18/18 RF + Debug, RAM 105.8 MB) taken from the ledger, not reproduced.

Passes: (1) core hunks outside Windows-only dirs, (2) win32 apprt + D3D11 renderer cross-task integration, (3) termio/pty/Command handle and shutdown lifecycle, (4) build system, (5) harness owner-safety spot check, plus ledger triage.

## Strengths

- **Isolation holds.** No core file imports the `win32` module (`git grep '@import("win32")'` outside apprt/renderer is empty). `std.os.windows` is only referenced from `src/os/windows.zig`. Almost every core hunk is either comptime-gated on `.windows` or an `.none => void` → `else => void` widening that is neutral for GTK/macOS. Upstream-only paths (`xdg.zig`, `homedir.zig`, `file_load.zig` refactor, `Exec.zig` posix branch, `main.zig` panic root) read as behaviour-identical on Linux/macOS.
- **Shutdown design is sound.** The overlapped read loop (`Exec.zig` `readLoopWindows`) waits on data and the quit event together, cancels and drains the OVERLAPPED before the buffer leaves scope, and slices `processOutput` into 2 KiB pieces with a quit check. `ClosePseudoConsole` runs on a helper thread and is idempotent (`console_closed`), `closeChildSide` is what makes EOF arrive, and `setSize` after close is a no-op. Child exit waits ≤500 ms for `drained` before telling the surface. Test coverage is unusually good (quit-while-blocked, quit-under-flood, 1 MiB/50 MB checksummed streams, ConPTY 1 MB checked lines).
- **Job/tree kill matches the owner's 2026-10-26 semantics already.** JOB_LIST attribute (never outside the job), no KILL_ON_JOB_CLOSE, console-only kill via PE subsystem, pid-reuse guard via `IsProcessInJob` (`Command.zig:562`) — the "FIX IN FINAL WAVE" item is done.
- **UI-thread re-entrancy is handled deliberately.** Every modal (close confirm, clipboard confirms) is reached via a posted message, never from inside a core callback; the clipboard queue's `abandoned` stack flag and `Window.handleClose`'s `fromUserData(hwnd)` re-check cover "surface destroyed under the dialog". `Surface.deinit` order (cancel clipboard → `initialized=false` → core deinit joins threads → `DestroyWindow`) keeps the render thread's `PresentTarget` pointers valid until joined; `hwnd_destroyed` avoids double destroy.
- **Lock order is consistent.** generic: `draw_mutex` → device context lock; `waitForFrameSlot` drops only the context lock (never `draw_mutex`) for the ≤100 ms wait; nothing takes `renderer_state.mutex` under the context lock. `MakeWindowAssociation(NO_WINDOW_CHANGES)` keeps DXGI from messaging the UI thread while it joins the render thread. No sync draws on the UI thread after 29.2.
- **Owner-machine safety in the harness is real:** desktop lock with stale detection, SKIP on locked/non-interactive desktop, layout diff restore, kills only registered `ghostty*` pids, clipboard backup with SKIP when non-text data is present, sandboxed HOME/LOCALAPPDATA/TEMP for every scenario.
- Both ledger "FIX IN FINAL WAVE" items landed (`windows_shell.zig:228` length guard, `IsProcessInJob`), and the Task 30b README wording was softened (e96668c19).

## Issues

### Critical

None.

### Important

**I1. `quit` exits without the running-process confirmation** — `src/apprt/win32/App.zig:241`
- `.quit => { PostQuitMessage(0); }`. Core leaves quit confirmation to the apprt (GTK: `application.zig:617` checks `core_app.needsConfirmQuit()` and shows a dialog). `ctrl+shift+q` is a default binding on non-Darwin (`Config.zig:6884`), so it is live on Windows.
- Failure: the user has vim with unsaved buffers, or a build, running and presses Ctrl+Shift+Q (or a mistyped Ctrl+Shift+W/Q). `App.terminate` destroys the window, `killTree` terminates the shell tree and the work is lost with no prompt. The close button and `close_surface` do confirm, so this is inconsistent as well as lossy. It breaks the DECISIONS "cross-platform features 1:1" rule for `confirm-close-surface`.
- Fix (about 15 lines, now): in the `.quit` arm, post a private message (`WM_APP+4` on `msg_hwnd`) so the dialog never runs inside `core_app.tick`. In its handler, `if (core_app.needsConfirmQuit() and !dialogs.confirm(first_window.hwnd, "Quit Ghostty", …)) return;` then `PostQuitMessage(0)`. Re-check that the window survived the dialog loop, as `Window.handleClose` does. M2 Task 21 (`WM_GHOSTTY_QUIT_CONFIRM`, `CloseKind.app`) generalises this. If the owner prefers to wait for M2, that should be an explicit owner acceptance, because daily M1 builds ship the lossy path.

**I2. Nothing shows that the core hunks still compile on Linux/macOS** (ledger Task 7 and Task 9 "open check: Linux/macOS cross-compile not verified" were never closed; Task 1 "needs macOS CI")
- The Global Constraint and the upstreamability goal require the core changes to be platform-gated and neutral. Several Windows modules are now imported unconditionally into shared roots: `global.zig` (`windows_log`, init/deinit at `:167`/`:250`), `main_ghostty.zig` (`windows_console` at `:35,:74,:84,:182`, `windows_log`), `main.zig` (panic root), `font/face/freetype.zig` (`WindowsFontFile`), `font/discovery.zig` (`freetype`, `WindowsFontFile`), `config/command.zig` (`windows_cmdline`), `os/main.zig` (`windows_shell`, `windows_cmdline`). Some Windows-named tests also run on all OSes (`Command.zig` "windows command: …", `Exec.zig` "windows tokenize: …", `Binding.zig` non-Latin test).
- I read every one: each relies on comptime early returns or lazy analysis and looks correct. But one comptime-unguarded reference to an extern in `src/os/windows.zig` (or a `void`-typed `job`/`read_thread_events` field used outside a comptime branch) would break the GTK build or link, and no build has ever exercised these paths.
- Fix (now): run `zig build -Dtarget=x86_64-linux-gnu -Dapp-runtime=none -j2` (core + libghostty + helper exe) on this machine through the test-lock and record the result in the ledger. If feasible, also do a compile-only test build for that target. Run the macOS check when CI exists (M6), and record that it is still pending.

### Minor

**M1. The Windows process handle is never closed** — `src/Command.zig:471` (`self.pid = hProcess`), `src/termio/Exec.zig:1151` (`externalExit`), `:1213` (`killCommand`).
- On Windows `Command.wait` does not close `pid`, and neither `externalExit` nor `stop`/`deinit` does. Each surface leaks one process handle and keeps the exited process object alive. libxev closes only its own duplicate.
- This is pre-existing upstream behaviour, but M1 now owns this lifecycle (`closeJob`, `hThread` close). It is negligible with one window. In M2, every closed tab or split leaks one.
- Fix: add `Command.closeProcess()` (Windows: `CloseHandle(pid)`, `pid = null`) and call it after `wait` in `killCommand` and in `externalExit`. Add a leak test via `GetProcessHandleCount` around start→stop.

**M2. The colour-glyph path in `freetype.zig:486` is not platform-gated, so GTK behaviour changes.**
- COLRv0 glyphs in FreeType faces on Linux now render coloured (before, `isColorGlyph` chose the BGRA atlas and `renderGlyph` produced gray, i.e. `error.WrongAtlas`). Every outline glyph of a colour-capable face now costs one extra load+render.
- This is a bugfix upstream would likely want, and it was accepted in the ledger (Task 12b). It still violates the letter of "core changes platform-gated". It also needs the changelog note that the ledger promised (see M3) and, ideally, its own upstreamable commit with a Linux test.

**M3. The milestone exit ritual is missing (SPEC §17 line 543): no upstream rebase and no owner-visible M1 changelog.**
- Base is still `cec8b92f1`, and there is no changelog anywhere under `docs/windows`. The M1 plan's Task 30 never listed these steps.
- Fix before calling M1 done: write a short changelog that includes the Linux COLR change, the Windows `direct:` quoting rule, `TERM=xterm-256color` and the known gaps (I1 if deferred, aarch64-msvc unverified, no device-lost recovery). Do the rebase now or record an explicit deferral.

**M4. Context-lock scope matters as soon as M2 adds surfaces** — `src/renderer/d3d11/Frame.zig:122-129`, `Frame.Dump`.
- Copy-to-backbuffer, `Present`, `Flush`, `CheckDeviceRemoved` and (with `GHOSTTY_D3D11_DUMP`) BMP file I/O all run under the device-wide context lock. With N surfaces, presents and dumps serialise. Combined with ledger Task 27 (bool slot tracking, effective latency up to 2) and the `draw_mutex` held during the slot wait, this is the most likely M2 frame-pacing or RAM-row risk.
- Fix in M2: measure first. Move the dump's file write after `drawFrameEnd`, and switch to a pending-waits counter.

**M5. DPI change applies the size before the scale** — `src/apprt/win32/Window.zig:256` (ledger Task 21/29.2). `SetWindowPos` (child WM_SIZE with the old scale) runs before `contentScaleCallback`, which causes one transient reflow per monitor hop. Set `content_scale` and call the callback before `SetWindowPos`. M2 already reworks DPI.

**M6. Device loss is terminal** (SPEC §6 line 186 says this is intended for M1). After a TDR or driver update every surface stops drawing until restart, and in M2 the tray keeps the process alive, so all windows are dead. The plan needs a device-recreate item (M2/M3).

## Deferred minors triage

Must fix before M1 is called done:
- I2: Linux cross-compile evidence (ledger Task 7/9 open checks, Task 1 glad/lib-vt link check, Linux part).
- M3: changelog, plus a rebase or a recorded deferral.
- I1: fix, or get explicit owner acceptance for M2 Task 21.
- Everything marked "FIX IN FINAL WAVE" is already done (verified at HEAD).

Roll into M2 (attach to the named M2 task):
- **Close/quit/lifecycle:**
  - Task 14 quit timer and last-window behaviour → M2 Task 28 (tray).
  - Task 21 spoofable `WM_CLOSE wparam=1` → M2 `messages.zig` close ids.
  - Task 18/21 MessageBox re-entrancy and second dialog via taskbar → M2 TaskDialog task.
  - M1 above (process handle leak) → first tab-close task (M2 Task 29).
  - Task 9 extra close thread per teardown.
- **Renderer with several surfaces:** Task 22 dump I/O under the shared lock; Task 27 bool slot drift, `draw_mutex` during the slot wait, once-per-renderer failure log; Task 17 `@enumFromInt` DXGI formats; Task 8 constant-buffer 256-byte scratch (custom shaders, M3); Task 8 debug factory before the debug-layer fallback.
- **Input:** Task 23 (Alt+numpad leak, shift consumed on shift+space, 64-byte cut, no message-logic tests); Task 24 (local `SystemParametersInfoW`/`GetClassNameW`, AltGr as ctrl+alt in mouse mods); Task 29.3 leftovers if any remain.
- **Config:** Task 29.4 `formatEntry` 4096-byte FBA for long `direct:` (hit by `+show-config` and reload in M2 Task 15); Task 7 mixed separators from `expandHome` and empty `XDG_CACHE/STATE_HOME` pinning test; Task 13 SPEC wording for the pwsh lookup.
- **Clipboard (M2/M3 hardening):** Task 26 (U+FFFD for invalid UTF-8, embedded NUL, unanswered osc_52_read after a failed confirm, C1/bidi in the preview, `global.alloc` inconsistency).
- **Logging (M3):** Task 16 (VT mode left on the parent console, CONOUT$ double open, rotation only at init, console code page).
- **Fonts (M3):** Task 12 index memory (~100–250 KB), mapped files blocking reinstall, first `discover()` latency; Task 12b synthetic bold/italic on COLR bitmaps.
- **Harness (with the M2 e2e work):** Task 21/28 Alt tap into the foreground app, all-SKIP exits 0, ANSI-match acceptance, the FLAKY wording; Task 30b Debug runtime of the 50 MB test.
- **Build hygiene (any time):** Task 1 memset condition repeated 3×, gui-entry rc not asserted; Task 4 `-Drenderer=d3d11` accepted on non-Windows; Task 5 lib-vt links Windows system libs, zon order; Task 2 dropped D3DCompile warnings, 11_0-only retry; Task 10 unused import, release-build `GHOSTTY_WIN32_EXIT_IMMEDIATELY` hook; Task 14 local `RegGetValueW`.
- **M6 CI:** `aarch64-windows-msvc` compile (criterion 10, not gating); macOS compile check (I2, macOS part).

## Declined to judge

- HLSL numeric parity with `shaders.metal` (no GPU run; the dump tests are the evidence).
- Full COM vtable correctness of `pkg/win32` beyond the slot-count tests, and refcounts on every D3D path (spot-checked only).
- e2e, RAM and throughput numbers (not re-run, by instruction).
- macOS impact (no SDK here); glad gating looks neutral by reading.
- Real CJK IME behaviour (IMM32 paths read only).
- ConPTY or DXGI behaviour on Windows 10 (best-effort target).
- Whether DXGI `CreateSwapChainForHwnd`/`Release` on the render thread could ever SendMessage to the UI thread on some driver. The design guards against it and the e2e close tests pass, but this cannot be proven by reading.

## Assessment

**Ready with fixes.** No critical defects. The threading, shutdown and handle lifecycle hold together across tasks. Before M1 is called done:
1. Fix I1 (quit confirmation), or record the owner's acceptance until M2 Task 21.
2. Produce the Linux cross-compile evidence (I2).
3. Do the SPEC §17 exit ritual: changelog, plus a rebase or a recorded deferral (M3).

The remaining minors roll into M2 as triaged above. M1 (the process handle leak) and M4 (context-lock scope) need to be handled early in M2, because tabs and splits multiply both.
