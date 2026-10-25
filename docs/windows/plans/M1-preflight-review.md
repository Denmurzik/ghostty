# M1 plan — pre-flight review

Reviewed: `docs/windows/plans/M1-core-and-window.md` against `DECISIONS.md`, `SPEC.md`, `recon/*`, and the source
(spot-checked at commit `c4296e29a`). Severity: BLOCKER = the plan as written fails or ships a broken core path;
IMPORTANT = will cost a re-plan or rework mid-wave; MINOR = cheap to fold in.

## Findings

1. **BLOCKER — Tasks 19, 24 (pacing design).** `generic.zig:1756` calls `api.drawFrameStart()` on *every* `drawFrame`, before
   the 0-size check (`:1763`) and the `needs_redraw` early return (`:1793`), and while `draw_mutex` is already held (`:1725`).
   A waitable-object wait in `drawFrameStart` therefore (a) consumes a latency token on draws that never `Present`, so the next
   real frame stalls the full 100 ms timeout. Generic draws on every wakeup, so this hits typing latency. (b) It blocks the UI
   thread for up to 100 ms inside `WM_SIZE` → `core.draw()`. SPEC §6.3 says "outside the lock", but that only holds for the
   context lock, not for `draw_mutex`. **Fix:** move the wait into `beginFrame` (it is only reached when a frame will
   really be drawn). Keep a `presented_since_wait` flag and wait only when it is set. Use timeout 0 on the sync/UI-thread
   path (`sync == true`). Add a test: 10 no-op `drawFrame` calls followed by one real frame take < 20 ms in total.

2. **BLOCKER — Task 11 (GUI-subsystem link).** `GhosttyExe.zig:45` sets `exe.subsystem = .windows`. This path has never
   linked upstream, because `emit_exe` is off when `app_runtime == .none`. With `link_libc` and a root `main`, Zig 0.17's
   `std/start.zig:31-36` exports only C `main`. lld picks `WinMainCRTStartup` for `/SUBSYSTEM:WINDOWS`, and the MSVC CRT
   then needs `WinMain`, so the link fails with an unresolved external. **Fix:** in Task 11 set
   `exe.entry = .{ .symbol_name = "mainCRTStartup" }` for Windows (GUI subsystem, normal `main`). Prove it in Task 1 with a
   10-line hello-GUI exe so the problem doesn't first show up in W4.

3. **IMPORTANT — Tasks 9, 15 (ConPTY EOF never arrives).** `WindowsPty.open` keeps `in_pipe_pty`/`out_pipe_pty` open in
   Ghostty until `deinit` (`pty.zig:457-461`). While Ghostty holds the write end of the output pipe, the read loop never sees
   `ERROR_BROKEN_PIPE` after `ClosePseudoConsole`. As a result `drained_event` never fires: every exit pays the 500 ms
   timeout and the drain guarantee does not hold. The Task 9 test still passes because it only checks that the token
   arrives. **Fix:** close both pty-side handles right after `CreateProcessW` succeeds (the MS sample does this). Add an
   assertion to test 3: the read loop reports EOF within 1 s of `closeConsoleAsync`. Also consider passing
   `bInheritHandles = FALSE` (or `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`) on the pseudo-console path (`Command.zig:426`, see #24).

4. **IMPORTANT — Tasks 13, 17, 19 (register collision).** The plan puts `bg_cells` at `t1` "VS+PS" and `atlas_color` at `t1`
   in the `cell_text` PS. SPEC §6.2 also binds `buffers[i≥1]` to `t(i)` and `textures[i]` to `t(i)` in the PS. In the
   `cell_text` pass the bg SRV and the colour atlas therefore overwrite each other's PS slot 1, and colour glyphs (emoji)
   sample a buffer SRV. **Fix:** give `bg_cells` its own register in both stages (e.g. `t4`). Define every register once in
   `common.hlsli` and mirror it in a `d3d11/slots.zig` table that `RenderPass` binds from, per stage. Add a Task 19 test that
   draws a BGRA atlas glyph next to a non-default bg cell.

5. **IMPORTANT — Task 22 (test encodes a bug).** `Surface.imePointScaled` (`src/Surface.zig:2246-2254`) already returns the
   *bottom* of the cursor cell, divided by the scale. The expected `POINT{15, 54}` adds the height a second time, which puts
   the candidate window one cell too low. **Fix:** expect `POINT{15, 30}`. Use `ime_point.height` only for `CFS_EXCLUDE`
   (exclude rect = `[y - height, y]`).

6. **IMPORTANT — Task 24 (swap-chain test is non-deterministic).** With `FLIP_DISCARD`, the back buffer's contents are
   undefined after `Present`, and `GetBuffer(0)` already returns the next buffer. Reading it back after `presentTarget` is
   not a valid oracle. **Fix:** split `presentTarget` into `copyToBackbuffer` + `present`. The test reads back between the
   two; a second test only checks that `Present` returns `S_OK` or `DXGI_STATUS_OCCLUDED`.

7. **IMPORTANT — Tasks 18, 24 (DXGI cross-thread deadlock).** The HWND belongs to the UI thread, while
   `Present`/`ResizeBuffers` run on the render thread *and* on the UI thread (sync draw from `WM_SIZE`). The DXGI
   multithreading guidance says the window's message thread must not block on a thread that is inside DXGI. Here `WM_SIZE`
   blocks on `draw_mutex` while the render thread may be inside `Present`. **Fix:** call
   `MakeWindowAssociation(NO_WINDOW_CHANGES | NO_ALT_ENTER)` before the first `Present` (state this explicitly). Never call
   `SetFullscreenState`. Add an e2e scenario to Task 25: live-resize loop (`SetWindowPos` ×200) while
   `cat /dev/urandom | base64` streams, with a 10 s hang watchdog. If it hangs, fall back to doing `ResizeBuffers` only on
   the render thread (the UI thread only stores the size and wakes the renderer).

8. **IMPORTANT — Task 18 (teardown order).** The parent's `DestroyWindow` destroys the child surface HWND. If that happens
   before `core_surface.deinit()` has joined the renderer thread, `Present` targets a dead HWND (DXGI errors or crash).
   Also, `WM_SIZE` arrives during `CreateWindowExW`, before `core_surface.init`. **Fix:** specify the order
   `Surface.destroy` = `core_surface.deinit()` (joins render + IO threads) → `DestroyWindow(child)` → free. `Window.destroy`
   destroys its surfaces first. Add an `initialized` guard so the WndProc ignores core callbacks until init is done.

9. **IMPORTANT — Tasks 19, 26 (RAM gate vs. `swap_chain_count = 3`).** Each generic `FrameState` (`generic.zig:395-447`)
   holds a full-size `Target` plus its own grayscale and colour atlas copies. With 3 frame states and 2 swap-chain buffers,
   a 4K surface needs about 5 × 33 MB of BGRA. Under WARP, or on an iGPU with shared memory, that lands in Private Bytes and
   breaks the ≤ 110 MB gate. Frame states buy nothing on D3D11: `WRITE_DISCARD` renames buffers, and `SetMaximumFrameLatency(1)`
   already caps queueing. **Fix:** `swap_chain_count = 1` for D3D11. Generic supports it, and `Frame.complete` already
   calls `frameCompleted` synchronously. Record this as a SPEC §6.1 change. Over-built otherwise.

10. **IMPORTANT — Task 26 (measurement mode).** The build mode isn't specified. Debug builds (debug allocator, unoptimised
    HLSL, debug layer) will overshoot 110 MB. Separately, `-Scenario scrollback` runs `seq`, but the SPEC §14 config is
    `command = direct:cmd.exe /k`, where `seq` doesn't exist. **Fix:** measure `-Doptimize=ReleaseFast`, record the mode in
    the CSV, and use `cmd /c "for /L %i in (1,1,200000) do @echo %i"` or a Git Bash config for scrollback.

11. **IMPORTANT — Tasks 1/11/14/25 (UTF-8 code page too late).** `activeCodePage=UTF-8` arrives only in Task 25, and the
    unit-test exe never gets a manifest. FreeType opens fonts with `FT_New_Face(path)` (`pkg/freetype/Library.zig:36`), i.e.
    narrow `fopen` in the ANSI code page. Per-user fonts under `C:\Users\Анна Ли\AppData\Local\Microsoft\Windows\Fonts`
    (`discovery.zig:1102-1109`) therefore fail to load, in tests and before Task 25. This is exactly Review Focus 1.
    **Fix:** move the manifest edit to Task 11. In Task 14, open fonts through a UTF-16 path: read or map the file with W APIs
    and use `initMemoryFace` (mapped read-only view, so no private-bytes hit), or use an `FT_Stream` over a wide handle. Add a
    test with a font copied to a non-ASCII temp dir.

12. **IMPORTANT — Task 20 (keyboard contract gaps).** The plan is missing several cases that all go through the WndProc:
    - `VK_PACKET` (0xE7). `SendInput KEYEVENTF_UNICODE` (the e2e `-Text` oracle, emoji panel, AutoHotkey) arrives as
      `VK_PACKET` + `WM_CHAR`. As specified, the RU/US e2e oracles exercise a path that real typing doesn't use.
    - UTF-16 surrogate pairs across two `WM_CHAR` messages (non-BMP text, emoji panel `Win+.`).
    - `WM_SYSKEYDOWN`/`WM_SYSCHAR`/`WM_SYSDEADCHAR`. Alt+key and F10 go there; pass Alt+F4 and Alt+Space to
      `DefWindowProc`, but nothing else, otherwise it beeps or opens the menu.
    - `VK_PROCESSKEY` (0xE5) must be ignored while the IME composes (contract with Task 22).
    - `WM_INPUTLANGCHANGE` must invalidate the cached `layoutHasAltGr`.
    - Task 11's loop must call `TranslateMessage` before `DispatchMessageW`, otherwise the `WM_CHAR` drain finds nothing.

    **Fix:** add these to the Task 20 interface and tests. Put the loop requirement in Task 11.

13. **IMPORTANT — Tasks 20, 22, 25 (GUI e2e can't run unattended as specified).** `SetForegroundWindow` from a background
    PowerShell is subject to foreground-lock rules. `SendInput` fails silently on a locked or RDP-minimised desktop, and
    `PrintWindow` returns black there. `-Layout <KLID>` needs a `WM_INPUTLANGCHANGEREQUEST` posted to the Ghostty HWND;
    loading the layout in the script process does nothing for Ghostty's thread. `LoadKeyboardLayoutW` (unit tests and e2e)
    can also add DE to the owner's input list permanently. **Fix:**
    - The harness pre-checks for an interactive, unlocked session and the foreground window, and reports SKIP rather than FAIL.
    - Use the `AllowSetForegroundWindow`/Alt-tap trick.
    - Post `WM_INPUTLANGCHANGEREQUEST`.
    - Unload only layouts that weren't loaded before (`GetKeyboardLayoutList` diff).
    - Add an in-process frame-dump env hook (`GHOSTTY_D3D11_DUMP=path`) as the primary pixel oracle; keep `PrintWindow`
      as secondary.

14. **IMPORTANT — Tasks 3, 5, all waves (worktree feasibility).** `zig-pkg/` (259 MB of fetched deps) is git-ignored, and
    `.zig-cache` is 2.2 GB cold. Each new worktree has to re-fetch (network) and cold-build all C deps. W4 runs 8 worktrees,
    each serialised through the test-lock, and each first build can exceed the 600 s Bash timeout. **Fix:** add a "worktree
    bootstrap" step: junction or copy `zig-pkg/` from the main checkout. Run the first build with `run_in_background` rather
    than a 600 s foreground call. Consider capping W4 at about 4 concurrent tasks.

15. **IMPORTANT — Tasks 11, 18, 19, 24, 25 (size).** These are clearly over one implementer's ~400 lines:
    - Task 11: runtime enum + 10 cross-file arms + `build.zig` + App/Window/util + tests.
    - Task 18: the full Surface contract + Window + 7 new files + `launch.ps1`.
    - Task 19: the entire D3D11 API + `Shaders.init` + Frame + 3 GPU tests.
    - Task 24: swap chain + pacing + PS capture.
    - Task 25: open-ended fixes plus an 8-scenario harness.

    **Fix:**
    - Split 11 into 11a (runtime enum + build wiring + empty `App.run`) and 11b (Window + wakeup + actions).
    - Split 18 into 18a (Surface + core contract) and 18b (Window hosting, DPI, `launch.ps1`).
    - Split 19 into 19a (`shaders.zig` pipelines + uniforms offset test) and 19b (D3D11 API + Frame).
    - Split 25 into 25a (harness, scenarios as separate scripts) and 25b..n (one bug per task, filed from FAIL output).

16. **IMPORTANT — Tasks 20–23 (same-wave file collisions in W6).** All four will need new constants in `pkg/win32/user32.zig`
    and `imm32.zig` (`VK_PACKET`, `KLF_*`, `WM_IME_*`, `WM_INPUTLANGCHANGE*`, `KEYEVENTF_*`, …), appended at the same EOF.
    Tasks 21 and 23, and 20 for per-surface key state, also need fields in `Surface.zig`. **Fix:** Task 18 pre-declares
    `keyboard_state: keyboard.State`, `mouse_state: mouse.State`, `ime_state: ime.State` (each type defined in its own
    file), so W6 tasks never edit `Surface.zig`'s struct. Task 6 adds the full constant set for W6 up front (from the list in
    #12), or the bindings get per-area sections with anchors.

17. **IMPORTANT — Task 10 (GUI subsystem loses panics).** In a GUI-subsystem exe, the Zig panic handler and
    `std.debug.print` write to an invalid stderr, so e2e crashes leave no trace in `ghostty.log`. **Fix:** in Task 10, add a
    root `panic` override (or `std.debug` hook) that appends the message plus stack trace to the file sink and
    `OutputDebugStringW` before aborting. Minidumps stay in M5.

18. **IMPORTANT — Task 14 (emoji render not verified).** The test only checks that discovery returns `seguiemj.ttf`. Whether
    FreeType renders its COLR glyphs as BGRA via `FT_LOAD_COLOR` (`face/freetype.zig:333-345`) is unverified. Win11's
    Segoe UI Emoji carries COLRv1, which FreeType does not rasterise through `FT_LOAD_COLOR`; that relies on the COLRv0
    fallback. **Fix:** add `test "windows font: U+1F600 renders as a colour glyph"` (`isColorGlyph == true`, atlas format
    BGRA). If it fails, record it as a known M1 gap: monochrome emoji until M3 DirectWrite.

19. **IMPORTANT — Task 25 (M1 exit criteria not covered).** SPEC §17 criterion (5) "`vim`/`less` usable" has no scenario.
    Child-exit handling isn't tested either: `exit` in the shell should close the window and quit the process when it is the
    last window, given the default `wait-after-command=false` (`show_child_exited` returns false in Task 18). **Fix:** add
    `vim-less` (open `less /etc/profile`, `q`; `vim -c ':wq! %TEMP%/gt-vim.txt'` + content oracle) and `shell-exit`
    (`exit` → process gone ≤ 3 s, no orphan `conhost.exe`/`OpenConsole.exe`).

20. **MINOR — Waves W4/W5 (shared files the self-review gets wrong).** `src/build/SharedDeps.zig` is edited by Tasks 8 and
    11 in the *same* wave W4; the self-review says "different waves". `src/os/windows.zig` gets EOF appends from 8, 9 and 10
    in W4, which guarantees textual conflicts. **Fix:** fold the `advapi32` link into Task 6's list now. Pre-create labelled
    sections in `windows.zig` (`// --- registry (T8)`, `// --- events (T9)`, `// --- console (T10)`), one per task.

21. **MINOR — Tasks 12, 13, 16, 17, 19, 24 (implicit app runtime).** These run `zig build test` without
    `-Dapp-runtime=none`. Once Task 11 merges (W4), the default becomes `win32`, and renderer tests start compiling the
    in-flight apprt. **Fix:** add `-Dapp-runtime=none` to every renderer/core test command; only `win32 ` filters use the
    default.

22. **MINOR — Task 9 (Zig 0.17 API).** `std.time.Timer` no longer exists in the 0.17 std (`lib/std/time.zig`), and neither
    does `std.Thread.sleep` (Task 23 test). **Fix:** use `std.Io.Timestamp.now(io, .awake)` deltas and `io.sleep(...)`, as
    `Exec.zig:122` already does.

23. **MINOR — Task 24 (ResizeBuffers flags).** `ResizeBuffers` must repeat the creation flags
    `FRAME_LATENCY_WAITABLE_OBJECT | ALLOW_TEARING`, otherwise it returns `DXGI_ERROR_INVALID_CALL`. Release the cached RTV
    and back-buffer refs first. A `Present` with `ALLOW_TEARING` is only legal with sync interval 0. State all three in the
    interface.

24. **MINOR — Task 15 (job assignment race).** `CREATE_SUSPENDED` + assign + `ResumeThread` works. On Win10+,
    `PROC_THREAD_ATTRIBUTE_JOB_LIST` in the existing attribute list (`Command.zig:370-386`) is atomic and avoids the suspended
    window. libxev's own nested job (`process.zig:262-266`) filters by pid, so nesting is fine (confirmed). Leave
    `bInheritHandles=TRUE` only for the no-pty path.

25. **MINOR — Task 23 (dangling payload).** `WM_GHOSTTY_CLIPBOARD_READ` carries a `*Surface`, and the surface can be closed
    before the message is processed. **Fix:** post a surface id and look it up in `App` (or drain pending requests in
    `Surface.destroy`).

26. **MINOR — Task 6 (types).** `CreateWindowExW`, `GetClipboardData`, `GetFocus` and `LoadCursorW` return a nullable value.
    Declare them as `?HWND`/`?HANDLE`. `HWND_MESSAGE` is `@ptrFromInt(@as(usize, @bitCast(@as(isize, -3))))`.

27. **MINOR — Task 10 (manual check).** A GUI-subsystem `ghostty +version` launched from interactive `cmd` returns the prompt
    before printing. The check should use `cmd /c "ghostty.exe +version | more"` or `start /wait`, or check the output
    through Git Bash's pipe handles. Document this as a known GUI-subsystem limitation.

28. **MINOR — DECISIONS (ARM64).** DECISIONS says aarch64 is cross-built, but M1 never compiles it. Hand-written
    vtables/structs are the risk. **Fix:** add `ZIG build -Dtarget=aarch64-windows-msvc -j4` (compile only) to the Task 26
    checklist, recorded but not gating.

29. **MINOR — over-built.** Task 2 Step 2 (handle-typed quit pipe) is fully replaced by Task 9 one wave later. Keep only the
    minimum needed to compile (or `@compileError`-free stubs), not tested behaviour. Re-running the full e2e under
    `-Driver warp` in Task 24 belongs in Task 26/CI, not every iteration.

## Checked and fine
Slot counts 43/115/25/29 match the SDK; `B8G8R8A8_TYPELESS`→`_UNORM` CopyResource and DYNAMIC structured/constant buffers
are legal; stub `surfaceSize=0` is safe (shaders lazy, `generic.zig:829,1820`); PerMonitorV2 + common-controls v6 + icon
already in `dist/windows/`; first-run template exists (`Config.zig:4219,4308`); `xev.Process` IOCP is job-based and
pid-filtered; `CREATE_UNICODE_ENVIRONMENT`+`CreateProcessW` keep Unicode argv/env; app-scoped Device (`Surface.zig:565`).
