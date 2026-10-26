# SDD ledger — plan: docs/windows/plans/M1-core-and-window.md

Spec: docs/windows/SPEC.md (authority with docs/windows/DECISIONS.md). Integration worktree: C:/D/den4ik/Ghostty, branch `windows`. Plan base: c4296e29a.
Owner asleep until 08:00 — no questions; rulings only.

## Pre-flight scan (lead)

### Shared files / interfaces between tasks
| Tasks | Shared | Producer → consumer | Finding |
|---|---|---|---|
| 1 ↔ 6 ↔ 8 ↔ 11 | src/build/SharedDeps.zig | distinct regions | different waves → no conflict |
| 2 ↔ 9 ↔ 15 | src/termio/Exec.zig | 2 fixes handles; 9 replaces Windows read loop; 15 kill+tokenizer | sequential waves (W2, W4a, W5) |
| 2,8,9,10,15 | src/os/windows.zig | append-only externs | spread over different waves; rebase conflicts possible at file end → impl resolves |
| 7 ↔ 8 ↔ 11 | src/config/Config.zig | distinct hunks | plan put them in one wave; split into W4a/W4b/W4c (ruling W) |
| 10 ↔ 2 | src/main_ghostty.zig | 2 fixes stdout API; 10 adds log sinks | different waves |
| 12 ↔ 17 ↔ 24 | pkg/win32/d3d11.zig, dxgi.zig | typed slots appended | different waves |
| 13 → 16 → 19 | d3d11/hlsl.zig Entry enum | 13 defines, 16 appends, 19 consumes | waves W4b → W4c → W6 |
| 4 → 12/17/19/24 | D3D11 stub names | 4 defines names, later replace bodies | ok |
| 11 → 18 → 20–23 | win32 Surface/App | 18 defines handler signatures | waves W4c → W5 → W6/W7 |
| 19 ↔ 24 | D3D11.zig, d3d11/Frame.zig | 24 adds present to 19's Frame | W6 → W7 |
| 18 ↔ 23 | apprt/win32/Surface.zig | 23 swaps close() confirm to dialogs | W5 → W7 |
| 18 ↔ 21 | apprt/win32/App.zig | 21 adds mouse actions | W5 → W6 |

### Per-task self-consistency
| Task | Check | Finding |
|---|---|---|
| 1 | verify greps vs edits | consistent |
| 2 | Step 2 uses windows.exp.kernel32 — verify symbol path exists | impl to confirm |
| 3 | vtable slot counts "by memory" | test text says recount from SDK header; ok |
| 4 | stub test runs only after T5 links | stated in plan |
| 5 | unbounded scope | size guard + NEEDS_CONTEXT; runs alone |
| 6 | 5 tests expected (4 spike + 1 user32) | consistent |
| 7–26 | tests ↔ produced interfaces | consistent on read; T10 manual check needs T11 (lead runs after W4c) |

## Rulings
- Ruling: waves [1,3] [2,4,6] [5] [7,9,12] [8,13,14] [10,11,16] [15,17,18] [19,20,21] [22,23,24] [25] [26] — plan's W4 (8 tasks) exceeds the 3-per-wave cap and puts Config.zig hunks of 7/8/11 together; re-split by file disjointness and deps — cost if wrong: a land conflict, resolved by rebase.
- Ruling: SPEC §18.1 single-instance ON by default (second launch → new window in running instance over the named-pipe IPC; config `single-instance`) — RAM goal — cost if wrong: one config default flip.
- Ruling: SPEC §18.2 Mica ON by default under the titlebar/tab strip only; terminal area opaque unless background-opacity < 1 — Windows 11 look without hurting text contrast — cost if wrong: default flip.
- Ruling: SPEC §18.3 toasts for portable builds by registering the AUMID under HKCU\Software\Classes\AppUserModelId at runtime; balloon fallback only if that fails — owner wants toasts — cost if wrong: M3/M5 rework of notifier.
- Ruling: SPEC §18.4 cache/state/logs under %LOCALAPPDATA%\ghostty — DECISIONS restrict only the config path — cost if wrong: path constant change.

## Plan revision (852709dde)
- Plan revised by architect after opus pre-flight review (docs/windows/plans/M1-preflight-review.md, 29 findings, all applied). Tasks renumbered 1–30 (+29.n). The pre-flight table above refers to the OLD numbering; the revised plan's Waves table + hot-file ownership list supersede it.
- Ruling: waves = the revised plan's W1–W13 table (≤3 per wave, disjoint files incl. hot files) — architect re-derived it from file lists under the lead's constraints — cost if wrong: a land conflict, resolved by rebase.
- Ruling: implementers sonnet effort high; reviewers sonnet (opus for concurrency/COM-heavy tasks 9, 19, 22, 27) — owner's model/effort instruction — cost if wrong: weaker review on a task.

## Execution
- W1 started: Task 1 → impl-1 (wt sdd-task-1, BASE 852709dde), Task 2 → impl-2 (wt sdd-task-2, BASE 852709dde). List items: plan task N = #(N+6); Final review = #37.
- Task 1: complete (commits 852709d..7d5a5a5, review clean)
- Task 1: minor (deferred): glad gated on renderer==opengl — confirm macOS/Metal + lib-vt still link (needs macOS CI)
- Task 1: minor (deferred): `!(windows and msvc)` memset condition repeated 3x — single constant
- Task 1: minor (deferred): gui-entry proof rc=7 not asserted automatically
- W2 partial start: Task 3 → impl-3, Task 4 → impl-4 (BASE 7d5a5a507); Task 5 waits for Task 2
- Task 3: complete (commits 7d5a5a5..61c215f, review clean; build evidence from report, re-verified by Task 6 build)
- Task 3: minor (deferred): closeFd ignores CloseHandle result (matches existing pattern)
- Task 2: complete (commits 852709d..d4eeb02 rebased onto windows, review clean; lead re-ran pkg/win32 tests: pass)
- Task 2: minor (deferred): test step does not run main.zig refAllDecls
- Task 2: minor (deferred): D3DCompile warnings dropped on success (log at debug/warn) — relevant for Task 11
- Task 2: minor (deferred): createDevice requests {11_1,11_0} only; no 11_0-only retry
- Task 2: minor (deferred): inconsistent null handling in getImmediateContext vs ID3DBlob.bytes
- Task 5 → impl-5 (BASE 551868b6f)
- Task 4: complete (review clean; stub test compiles/runs in Task 6)
- Task 4: minor (deferred): imageTextureOptions panics for .gray/.bgra — total mapping needed by Task 22
- Task 4: minor (deferred): -Drenderer=d3d11 accepted on non-Windows targets
- Task 4: minor (deferred): initShaders uses alloc arg not self.alloc
- Task 5: complete (review clean, rebased)
- Task 5: minor (deferred): SharedDeps Windows block links win32/d3d11/dxgi for lib-vt consumers too (duplicated with module links)
- Task 5: minor (deferred): build.zig.zon .win32 not alphabetical
- Task 5: minor (deferred): GetStockObject returns ?HANDLE vs hbrBackground ?HBRUSH (ptrCast needed)
- Task 5: note: OOM at -j4 when other builds ran concurrently; implementer used -j2
- W3: Task 6 → impl-6 (BASE c6d28a2c1), alone
- Task 6: complete (no code changes needed; core + test exe build/link/run on windows-msvc: config 260/4skip, Exec 81/7skip, xev 75 pass; d3d11 stub test pass)
- Ruling: builds use -j2 (tests) and -j1 for full `zig build` when OOM occurs — another session on this machine builds concurrently; -j4 OOMed twice — cost if wrong: slower builds
- W4 started: Tasks 7, 8, 9 (BASE c6d28a2c1)
- Task 7: complete (review clean)
- Task 7: minor (deferred): empty XDG_CACHE/STATE_HOME on Windows now → LOCALAPPDATA; add pinning test
- Task 7: minor (deferred): file_load.zig:114 comment vs legacyDefaultXdgPath still returning legacy path on Windows
- Task 7: minor (deferred): expandHome on Windows yields mixed separators
- Task 7: open check: Linux/macOS cross-compile not verified (wave-end or CI)
- Task 10 → impl-10 (BASE 38aa14f3b), started while 8/9 run (files disjoint)
- Task 8: review → Needs fixes (1 Important: structured-buffer SRV unreachable via Handle). Fix round 1 dispatched to impl-8 (FIX_BASE 4c9aeb328)
- Task 8: minor (deferred): constant-role initFill 256-byte scratch (shadertoy Uniforms ~4.5KB would fail; unreachable today)
- Task 8: minor (deferred): DXGI debug factory created before debug-layer fallback → init fails without Graphics Tools
- Task 8: minor (deferred): no sync test for constant-role buffer
- Task 8: note for Task 22: D3D11.drawFrameStart/End must call device.lockContext/unlockContext (sync/replaceRegion assert the lock)
- Task 8: fix round 1/5 (1 addressed, 0 open; commits 4c9aeb3..3ba1d9b)
- Task 8: complete (review clean after fix round 1)
- Task 11 → impl-11 (BASE 5916aac37)
- Task 9: review (opus) → Needs fixes (1 Critical: setSize after closeConsoleAsync UAF on HPCON). Fix round 1 dispatched (FIX_BASE c6b0e40d1)
- Task 9: minor (deferred): drain wait may time out if termio mailbox full (bounded; comment)
- Task 9: minor (deferred): sync-completed overlapped ReadFile uses lpNumberOfBytesRead (MS recommends NULL + GetOverlappedResult)
- Task 9: minor (deferred): closeConsoleAsync in threadExit redundant (extra thread per close)
- Task 9: open check: POSIX/Linux cross-compile not verified
- Task 10: complete (review clean)
- Task 10: minor (deferred): win32 Surface getSize/getCursorPos return defaults not errors (Task 18 replaces)
- Task 10: minor (deferred): unused builtin import in win32/App.zig; exitImmediately env hook in release builds
- Task 10: note: running ghostty.exe without XDG override creates the real %USERPROFILE%\.config\ghostty\config.ghostty (expected product behaviour; harness must use temp XDG_CONFIG_HOME)
- Task 14 → impl-14 (BASE 2088de472)
- Task 9: fix round 1/5 (1 addressed, 0 open; commits c6b0e40..55c1e1e)
- Task 9: complete (review clean after fix round 1)
- Task 12 → impl-12 (BASE 4969e87e7)
- Task 11: complete (review clean, opus: HLSL port verified line-by-line vs shaders.metal)
- Task 11: Ruling: plan-mandated atlas t0/t1 + s0 declared globally in common.hlsli may collide with image shaders' t0/s0 — Task 15 may move atlas/sampler declarations into cell_text.hlsl (and relax the slots text test) if FXC reports overlapping registers — cost if wrong: one shader refactor
- Task 11: minor (deferred): failed compile not cached (recompiles + warns each call)
- Task 11: minor (deferred): D3DCompile success warnings dropped (likely X3571 pow) — log error blob on success in Debug (pkg/win32/d3dcompiler.zig)
- Task 11: minor (deferred): Load vs clamp_to_edge sampling difference (no effect within glyph rect)
- Task 11: carry to Task 17: CellText input layout uint2,uint2,int2,uint2,uint4,uint,uint TEXCOORD0..6; DrawInstanced start vertex 0; colour atlas B8G8R8A8_UNORM_SRGB; cull mode none; global.io() ready before bytecode()
- Task 15 → impl-15 (BASE 09dbc1881)
- Task 14: complete (review clean)
- Task 14: minor (deferred → M2): last-window close always posts WM_QUIT; quit-after-last-window-closed + delay unreachable; fix with single-instance (M2). startQuitTimer doc comment wrong.
- Task 14: minor (deferred): local RegGetValueW extern in apprt util.zig — move to pkg/win32/advapi32.zig
- Task 14: minor (deferred): terminate() loop can spin if DestroyWindow fails; Window.create errdefer pop not keyed by pointer; wakeup re-arm not tested
- Task 18 → impl-18 (BASE 9ce1447f5)
- Task 17 → impl-17 (BASE 9ce1447f5)
- Task 15: complete (review clean, opus); atlas t0/t1 moved into cell_text.hlsl per ruling
- Task 15: minor (deferred): redundant bounds check in bg_image load_or_zero; per-pixel GetDimensions in bg_image (negligible)
- Task 15: carry to Task 20 (input layouts): Image TEXCOORD0..3 = R32G32/R32G32/R32G32B32A32/R32G32 float; BgImage TEXCOORD0 R32_FLOAT, TEXCOORD1 R8_UINT @4, stride 8
- Task 18: review → Needs fixes (1 Critical: create() missing core_app.addSurface). Fix round 1 dispatched (FIX_BASE 631d8bb37)
- Task 18: minor (deferred): modal MessageBoxW in close() re-enters wndProc (Task 26 to check held locks)
- Task 18: carry to Task 21: Window.destroy must destroy the Surface before freeing Window; parent WM_SIZE → MoveWindow child + forward minimize → occlusionCallback(false); forward WM_DPICHANGED re-layout; wire App set_title → Surface.setTitle
- Task 12: complete (review clean; colour-emoji test SKIP honest)
- Task 12: Ruling: colour COLR glyphs (Segoe UI Emoji) currently fail with error.WrongAtlas (renderGlyph flattens BGRA via FT_Bitmap_Convert) and promoteFallbacks puts Segoe UI Emoji first — user-visible; add follow-up Task 12b (render colour glyphs with .render=true into the existing FT_GLYPH_FORMAT_BITMAP branch, ~20-40 lines in src/font/face/freetype.zig + fix log wording) to M1, run when a writer slot frees — cost if wrong: emoji missing until fixed
- Task 12: minor (deferred): finalizer-before-done_face ordering relies on FreeType memory-stream internals (comment)
- Task 12: minor (deferred): index duplicates family/style strings per face (~100-250 KB)
- Task 12: minor (deferred → Task 30): measure first discover() latency; codepoint probe may open ~1000 files (coverage cache backlog)
- Task 12: minor (deferred): mapped font files block font reinstall while running
- Task 13 → impl-13 (BASE 1356b6f00)
- Task 18: fix round 1/5 (1 addressed + optional minor, 0 open; commits 631d8bb..a5cb72e)
- Task 18: complete (review clean after fix round 1)
- Task 18: carry to Task 27: check renderer thread join vs blocking Present deadlock on surface destroy
- Task 21 → impl-21 (BASE 0802da3fc)
- Task 21: Ruling: impl-21 adds mouse.State{shape=.text, hidden=false} in mouse.zig (outside its file list); WM_SETCURSOR stays with Task 24 — smallest place for the state Task 24 consumes — cost if wrong: trivial move
- Task 12b → impl-12 resumed (has Task 12 context), wt sdd-task-12b (BASE 0802da3fc)
- Task 17: complete (review clean; clear-on-first-step deviation from GL verified unobservable by generic.zig)
- Task 17: minor (deferred → Task 22): unbind PS t0..t2 and VS/PS t4+ SRVs in RenderPass.complete() (post-pass ping-pong hazard warnings)
- Task 17: minor (deferred → Task 22): sRGB target path (srgb=true used by initTarget) never drawn/read back in tests
- Task 17: minor (deferred): DXGI formats via @enumFromInt in Pipeline.zig — add named members to pkg/win32/dxgi.zig
- Task 20 → impl-20 (BASE dd329dfa1)
- Task 12b: review → Needs fixes (1 Important: COLR bitmap placed/sized from outline metrics). Fix round 1 dispatched (FIX_BASE 726426c36)
- Task 12b: minor (deferred): 3 loads + throwaway raster for non-colour glyphs in colour faces; mono target config not covered; Linux COLR faces now coloured (note in changelog)
- Task 13: complete (review clean)
- Task 13: minor (deferred, FIX IN FINAL WAVE): windows_shell.systemExists wtf8ToWtf16Le into 2048-u16 buffer without length guard → OOB panic for a ≥2 KB PATH entry; add `if (path.len >= buf.len) return false`
- Task 13: minor (deferred): WSL guard only tested directly; finalize .windows branch untested under is_test; SPEC §8.3 says PATH+PATHEXT for pwsh but impl uses pwsh.exe only (update SPEC)
- Task 13: carry to Task 19/28: `.direct` argv with space in argv[0] (C:\Program Files\Git\bin\bash.exe) must be quoted correctly in CreateProcessW command line
- Task 16 → impl-16 (BASE )
- Task 16 → impl-16 (BASE 9e30448b9)
- Task 20: complete (review clean)
- Task 20: minor (deferred): hlsl_uniform_offsets is a hand-mirrored table (not parsed from common.hlsli); custom-shader warn prints in test output
- Task 22 → impl-22 (BASE 45cb08fd7)
- Task 21: complete (review clean; live harness run: cmd child, close-confirm, no orphans)
- Task 21: minor (deferred → Task 26): Surface.close confirm doesn't set Window.confirming_close (possible 2nd dialog via taskbar close); route through requestCloseWithConfirm
- Task 21: minor (deferred): WM_CLOSE wparam==1 "already confirmed" marker spoofable → private WM_APP msg or bool
- Task 21: minor (deferred): DPI scale updated after SetWindowPos (child WM_SIZE sees old scale); dead child SIZE_MINIMIZED branch
- Task 21: minor (deferred → Task 28): Harness Set-ForegroundSafe sends Alt tap to foreground app; non-terminating errors = PASS; layout restore order; temp xdg-* dirs not cleaned; launch.ps1 pid registration when not dot-called
- Task 23 → impl-23 (BASE fc021bce3)
- Task 12b: fix round 1/5 (1 addressed, 0 open; commits 726426c..ce0c417)
- Task 12b: complete (review clean after fix round 1; Segoe UI Emoji renders in colour with correct metrics)
- Task 12b: minor (deferred): test reaches into Face internals; synthetic bold/italic not applied to COLR bitmaps
- Task 24 → impl-24 (BASE d62f94f18)
- Task 16: review → Needs fixes (1 Important: panic hook has no re-entry guard; message written only with the trace). Fix round 1 dispatched (FIX_BASE 7064989dc)
- Task 16: minor (deferred): VT processing mode left enabled on parent console; CONOUT$ opened twice / handle leak on SetStdHandle failure; deinit vs concurrent writeRaw window (document precondition); >4096 line not atomic; GHOSTTY_LOG parse error re-enables file logging for CLI actions; panic trace start frame differs; console test near-vacuous; log rotation only at init; console code page not UTF-8
- Task 22: Ruling: HLSL load_color must NOT convert sRGB→Display P3 (Metal does it only because CAMetalLayer is P3; GLSL path has no conversion; DXGI backbuffer is sRGB) — match GLSL; impl-22 edits common.hlsli before review — cost if wrong: colours shift on wide-gamut displays with window-colorspace=display-p3 (M3 colour management item)
- Task 16: fix round 1/5 (1 addressed + optional minor, 0 open; commits 7064989..f52cd30)
- Task 16: complete (review clean after fix round 1)
- Task 19 → impl-19 (BASE ce9756efa)
- Task 22: complete (review clean, opus)
- Task 22: carry to Task 28: read dumps with [IO.File]::ReadAllBytes + BMP header parse (System.Drawing.Bitmap locks the file → atomic replace fails silently)
- Task 22: carry to Task 27: sync derived from thread identity (render_thread null before threadEnter) — verify before making waitForFrameSlot blocking; confirm TYPELESS Target → B8G8R8A8_UNORM backbuffer copy
- Task 22: minor (deferred): dump readback + file I/O under shared context lock (copy under lock, write after drawFrameEnd); colour atlas test uses 255/0 (unlinearize untested); Dump.initFromEnv untested; dead srgb_to_display_p3 in common.hlsli; slot-check placement cosmetic
- Task 24: Ruling: impl-24 may add mouse.refreshCursor(surface) after mouse_shape/mouse_visibility in App.zig (immediate cursor update) — before review — cost if wrong: trivial
- Task 27 → impl-27 (BASE f85c2a029)
- Task 26 → impl-26 (BASE f85c2a029)
- Task 24: review → Needs fixes (2 Important: precision wheel 3x slow; horizontal precision uses cell.height). Fix round 1 dispatched (FIX_BASE 0e9028041)
- Task 24: Ruling: precision wheel deltas → pixels = delta/120 × SPI_GETWHEELSCROLLLINES (fallback 3) × cell_height (horizontal: SPI_GETWHEELSCROLLCHARS × cell_width) so precision and notch wheels scroll the same distance — mirrors GTK's compensation — cost if wrong: touchpad scroll speed tuning
- Task 24: minor (deferred): isSurfaceWindow/GetClassNameW local + duplicated class name; AltGr as ctrl+alt in mouse mods; refreshCursor skips captured surface over another window
- Task 24: fix round 1/5 (2 addressed + optional minor, 0 open; commits 0e90280..16d196d)
- Task 24: complete (review clean after fix round 1)
- Task 24: minor (deferred): SystemParametersInfoW declared locally in mouse.zig (move to pkg/win32)
- Task 23: review (opus) → Needs fixes (2 Important: AltGr synthetic LCtrl suppression dead code; RU ctrl+shift+c not matching unicode 'c' binding). Fix round 1 dispatched (FIX_BASE 1aee99f11)
- Task 23: Ruling: platform-agnostic core fallback in Binding.Set.getEvent — when unshifted_codepoint is non-ASCII and nothing matched, try .unicode = event.key.codepoint() (physical US codepoint); Latin layouts unaffected — cost if wrong: a binding could fire on non-Latin layouts where the user intended otherwise (upstream-visible core change)
- Task 23: minor (deferred): Alt+numpad digits leak as alt+numpad_N before composed WM_CHAR; dead-key utf8 goes through unicode binding lookup (GTK passes empty); shift consumed for shift+space; 64-byte buffer may cut mid-UTF-8; fake shifts sent as .unidentified; no message-logic tests in keyboard.zig
- Task 23: fix round 1/5 (3 addressed, 1 new Important from my own ruling: Binding fallback too broad; commits 1aee99f..4be69f8)
- Task 23: Ruling (supersedes earlier): Binding getEvent non-ASCII fallback restricted to physical key_a..key_z AND gated to Windows — Latin layouts with non-ASCII keys (DE ß, FR ç, CZ, Nordic, ES) must keep sending to the pty; core changes stay platform-gated — cost if wrong: Greek/Hebrew/Arabic etc. covered; letter-only scope may miss rare layouts
- Task 23: fix round 2 dispatched (FIX_BASE 4be69f805)
- Task 25 → impl-25 (BASE 3593a7971)
- Task 26: review → Approved with minors; Ruling: promote 4 minors to required (test can hang runner + hold test-lock; flaky timing; tests destroy owner's non-text clipboard → SKIP when non-text formats present; setClipboard exact "text/plain" match → isTextMime) — owner-machine safety beats the minor/defer rule — cost if wrong: one extra fix round. Fix round 1 dispatched (FIX_BASE 947d0357c)
- Task 26: minor (deferred): invalid UTF-8 OSC52 payload → write error after confirm (use U+FFFD); embedded NUL truncates; confirmed completeClipboardRequest failure leaves osc_52_read unanswered; .list (mode 5522) unsupported → paste no-op; previewText doesn't escape C1/bidi overrides (hardening); global.alloc inconsistency
- Task 23: fix round 2/5 (1 addressed, 0 open; commits 4be69f8..e00f0dd)
- Task 23: complete (review clean after 2 fix rounds)
- Task 19: review (opus) → Approved, but raises owner-level semantics: KILL_ON_JOB_CLOSE kills GUI apps launched from the shell (start notepad, code .) on tab close and on Ghostty crash, unlike Windows Terminal/upstream
- Task 19: Ruling: GUI apps launched from the shell must survive (Windows Terminal behaviour) — drop KILL_ON_JOB_CLOSE; keep the job only to enumerate the tree; on surface close terminate only job processes whose image is a CONSOLE-subsystem PE (QueryFullProcessImageNameW + PE header subsystem), GUI-subsystem processes are left running; Ghostty crash → ConPTY teardown handles console clients — cost if wrong: a console grandchild detached from the console could survive; owner may prefer the stricter kill-all
- Task 19: fix round 1 dispatched (FIX_BASE 70856f8fb) incl. minors: test must assert ≥2 pids opened; empty-arg "" quoting + argv[0] trailing backslash in windowsCreateCommandLine; drop unused decls
- Task 25: review → Needs fixes (plan-mandated defect: IME commit via textCallback = bracketed paste). Ruling: deviate from the brief — commit via keyCallback(.unidentified, utf8=str) after preeditCallback(null), like GTK imCommit — cost if wrong: none expected (matches GTK). Fix round 1 dispatched (FIX_BASE ad83b4e31)
- Task 25: carry to Task 28/29: keyboard must skip VK_PROCESSKEY key-downs itself (not only via ime_state.composing) — verify at integration; manual MS-IME check still SKIPPED (no CJK IME installed)
- Task 27: visual evidence OK (lead viewed capture.png: GHOSTTY-M1 legible, bg #102030); black edge strips = capture script artifact (GetWindowRect incl. DWM invisible borders), not the renderer
- Task 27: review (opus) → Needs fixes (2 Important: MakeWindowAssociation before swap chain creation; capture-window.ps1 window-vs-client coords) + required minor: waitForSlot consumes slot on timeout. Fix round 1 dispatched (FIX_BASE a3340ec13)
- Task 27: minor (deferred): draw_mutex held during ≤100 ms slot wait blocks UI sync draws; weak no-op-draw and 0x0 tests; swap_chain_failure_logged once per renderer
- Task 27: carry to Task 28/29: slow resize while streaming (~400 ms/resize, not Present-related)
- Task 27: resize-slowness hypothesis (review-27, for 29.n): UI WM_SIZE → sizeCallback pushes .forever into a possibly full termio mailbox (src/Surface.zig:2638-2645); draw() then waits draw_mutex held by renderer rebuildCells waiting the terminal mutex (generic.zig:1419,1647) held by termio during scrollback reflow; plus ConPTY ResizePseudoConsole full repaint (pty.zig:580). Measure around Surface.zig:306-309 handleSize, pty.zig:580, Termio terminal.resize. Idea: coalesce WM_SIZE (apply on timer / WM_EXITSIZEMOVE) and avoid synchronous draw on UI thread during live resize.
- Task 26: fix round 1/5 (4 addressed, 0 open; commits 947d035..62bd5ce)
- Task 26: complete (review clean after fix round 1); clipboard tests SKIP when clipboard holds non-text formats
- Task 19: fix round 1/5 (all addressed; commits 70856f8..b30ce77)
- Task 19: complete (review clean after fix round 1)
- Task 19: minor (deferred, FIX IN FINAL WAVE): pid-reuse race in killTree — verify IsProcessInJob after OpenProcess before TerminateProcess
- Task 19: OWNER QUESTION (morning): `start cmd` / `start python x.py` open a separate console window (CUI) and are killed when the Ghostty tab closes; detached console processes survive a shell self-exit. Alternative = pure Windows Terminal semantics (kill only the direct child, rely on ClosePseudoConsole CTRL_CLOSE for attached clients). Current M1 behaviour kept until the owner decides.
- Task 25: fix round 1/5 (all addressed; commits ad83b4e..713131a)
- Task 25: complete (review clean after fix round 1)
- Verified: keyboard.zig:85 skips VK_PROCESSKEY key-downs (Task 25 carry-over closed)
- Task 27: fix round 1/5 (3 addressed; commits a3340ec..0723579)
- Task 27: complete (review clean after fix round 1; lead viewed capture-client.png: clean)
- Task 27: minor (deferred → final review): waitForSlot bool can't track >1 unpaid present → semaphore drift ≤ buffer count, effective latency ~2 (use pending_waits counter); first-frame wait skipped by design; pacing asserts removed from D3D11 tests; capture script assumes PowerShell DPI awareness matches the window; local kernel32 externs in SwapChain.zig
- Integration check after W10 (lead, c5d856f63): zig build -j2 OK; tests win32 / d3d11 / windows filters exit 0
- W11: Task 28 → impl-28 alone (BASE c5d856f63)
- Coordination: fastlook-12 session asked to pause GUI e2e (foreground stealing). impl-28 paused 10 min; agreed shared desktop lock %TEMP%\gui-e2e.lock for all future GUI/input runs (add to Harness in 29.n)
- Task 28: DONE_WITH_CONCERNS (17 scenarios; Debug 12 PASS/2 FAIL/3 SKIP, ReleaseFast 15/1/1). Bugs → 29.1 close-while-streaming slow exit (Debug), 29.2 resize-while-streaming UI hang (SPEC §6.4 fallback), 29.3 typed text via textCallback = per-char bracketed paste (+ send-input Unicode VkKeyScan, RU ctrl+shift+c e2e), 29.4 `direct:` keeps quotes on Windows
- Ruling: on Windows `direct:` commands are tokenized with MS C runtime rules (tokenizeWindows) so quoted paths with spaces work; other OS unchanged — Windows convention — cost if wrong: a literal quote in a direct: arg needs escaping
- Ruling: 29.2 adopts the SPEC §6.4 fallback (no sync draw on WM_SIZE; coalesced sizeCallback via timer + WM_EXITSIZEMOVE) — Debug hang observed — cost if wrong: slightly laggier live-resize visuals
- Waves for 29: A = [29.1 Exec/pty, 29.2 apprt Surface/Window, 29.3 keyboard + send-input]; B = [29.4 config/command.zig, 29.5 final-wave minors]
- Task 28: review → Needs fixes (2 Important: retry masks product FAILs as PASS; SKIP when default shell ≠ bash hides shell-discovery regression) + required minor: clipboard restore after timeout kill. Fix round 1 dispatched (FIX_BASE 709b97fd8)
- Task 28: minor (deferred): ANSI-match acceptance in Assert-ShellText; best-of-two startup; typing-us payload missing ' and `; all-SKIP run exits 0
- 29.1 → impl-29-1, 29.2 → impl-29-2 (BASE c5d856f63; e2e scripts land with Task 28 — implementers rebase before the e2e step)
- Task 28: fix round 1 extended with Important #3: GUI lock not atomic / can leak / unconditional release / goes stale / runner-only → atomic CreateNew + GUID ownership + heartbeat + Harness-level acquisition + README protocol
- Task 28: fix round 1/5 (I1, I2, clipboard addressed; I3 partial — inherited lock rewrites pid → stealable). Fix round 2 dispatched (FIX_BASE 418eb4985) incl. stale-takeover re-read, LF restore, backup handled at run start
- Task 28: fix round 2/5 (all addressed; commits 418eb49..de12db0)
- Task 28: complete (review clean after 2 fix rounds); last full Debug run PASS 14 / FAIL 3 (known: 29.1, 29.2, 29.3)
- Task 28: minor (deferred → 29.5): run-start clipboard backup restore is unguarded (pass guard 'gt-pa.txt'); stale-takeover tiny non-atomic window; FLAKY lines in results.txt
- 29.3 → impl-29-3 (BASE de12db05e)
- Task 29.1: complete (review clean, opus): Windows read thread slices processOutput into 2 KiB with quit check; Debug close-while-streaming 0.5–0.7 s
- Task 29.1: carry to Task 30: verify ReleaseFast close-while-streaming ≤1 s AND throughput (e.g. cat a large file) after slicing; if costly → 8–16 KiB slices or no slicing in ReleaseFast
- Task 29.1: minor (deferred): no delivery-order test through processSlicedWindows; redundant first-slice quit check comment
- Note: Debug ~5 KB/s VT throughput is upstream slow_runtime_safety (Page.assertIntegrity), not a port bug — Debug e2e timings measure integrity checks; acceptance timings must use ReleaseFast/ReleaseSafe
- 29.4 → impl-29-4 (BASE 4ea155c12)
- Note: zig fmt --check flags src/apprt/win32/mouse.zig (Task 24) → fix in 29.5
- Task 29.3: complete (review clean): typed text → keyCallback(key.textEvent); send-input Unicode; typing-* e2e 7/7 PASS
- Task 29.3: minor (deferred → 29.5): ime.zig should use key.textEvent; WM_UNICHAR should return TRUE after delivery; send-input help line reflow
- 29.5 → impl-29-5 (BASE c6d6f9ba9)
- Task 29.4: Ruling: empty `direct:` on Windows → error.ValueRequired (was argv {""}) accepted; Config.zig command doc gets one Windows-quoting sentence (impl-29-4)
- Task 29.5: note: one win32 test run printed "failed command ...ghostty-test.exe" next to clipboard SKIP logs with exit 0; rerun clean — investigate flake in Task 30 acceptance runs
- Task 29.4: complete (review clean): direct: uses MS rules on Windows; tokenizer moved to src/os/windows_cmdline.zig
- Task 29.4: minor (deferred): formatEntry Windows path uses a 4096-byte FixedBufferAllocator with growing writer → +show-config may OOM for ≥1.5 KB direct commands; windows_cmdline.zig has no co-located tests
- Task 29.5: complete (review clean; 7 items)
- Task 29.2: root cause measured by impl-29-2: renderer_state.mutex starvation (unfair std.Io.Mutex; read loop hot lock/unlock; only lockDemand waiters get handoff) → WM_MOUSEMOVE 8-30 s, Termio.resize lock wait 6-10 s. Ruling: rebase on 29.1 slicing and re-measure first; if still >100 ms, approved: Termio.resize + Surface UI-thread renderer_state.mutex sites → lockDemand/unlockDemand (platform-neutral, existing mechanism) — cost if wrong: upstream-visible core change in lock usage
- Task 29.2: Ruling: resize-while-streaming acceptance on ReleaseFast (Debug reference-only; upstream slow_runtime_safety); impl rebases on 29.1 and reruns once; SPEC §6.4 updated to coalesced resize — cost if wrong: Debug users see stalls under heavy streaming
- Task 29.2: review (opus) → coalescer approved; Ruling: DROP core commit 135ed6144 (lockDemand in Surface/Termio) — not platform-gated, gain within noise, incomplete — cost if wrong: Debug-only UI stalls up to ~1.5 s under heavy streaming. Fix round 1 dispatched (revert + SPEC sentence + applySize records applied only on success + ReleaseFast acceptance run)
- Task 29.2: minor (deferred): DPI contentScaleCallback immediate while size waits ≤16 ms (one transient reflow); dead request(0) on !visible
- Task 29.2: fix round 1/5 (core commit reverted, applySize fixed; commits 866d616..43789b0)
- Task 29.2: complete (review clean): coalesced resize, no sync draw; ReleaseFast resize-while-streaming 200 resizes/0.48 s, WM_NULL ≤1 ms
- Task 29 (29.1–29.5): complete
- W13: Task 30 → impl-30 alone (BASE 43789b095)
- RESTART (session crash ~09:17–11:30): impl-30 lost. Left in wt sdd-task-30 (uncommitted): measure-ram.ps1, ram-baseline.csv, Device.zig PrivateUsage logs, README; evidence: e2e ReleaseFast 18/18 PASS, e2e Debug 18/18 PASS; tests config 271/4skip, d3d11 125, font 209/16skip, input 400/8skip, windows 146 all pass; terminal filter: combined build OOM (bad_alloc), split run A stalled at 619/829 "PageList eraseRowBounded multi-page invalidates viewport offset cache"; ARM64 aarch64-windows-gnu built ghostty.exe; RAM one-surface RF 105.1-105.8 MB (gate 110 OK), WARP 69.5, scrollback 153.4. Task list recreated: Task 30 = #1, Final review = #2. Respawned impl-30b.
- Task 30: impl-30b DONE_WITH_CONCERNS (08b1379f2): RAM gate PASS 105.8/110; terminal 1562 pass/6 skip (829 PageList+Terminal all pass; earlier "stall" was buffered output); win32 3× clean; e2e RF 18/18, Debug 18/18; ARM64 gnu builds; SPEC §17 criteria 1–9 PASS, 10 gnu-only
- Task 30: CONCERN (load-bearing): throughput screenshot shows the LAST streamed line "The quick brow fox" (missing 'n') — possible byte loss in the Windows output path (29.1 slicing / Task 9 overlapped ReadFile byte count / ConPTY). Ruling: open Task 30b "stream integrity" (opus investigate+fix with checksum-verified repro) before the final review — cost if wrong: an hour of investigation
- Task 30b → impl-30b-opus (opus; BASE 43789b095)
- Task 30: complete (review clean)
- Task 30: minor (deferred → M2): CSV rows stamped with base SHA not 08b1379f2; aarch64-windows-msvc unverified (no ARM64 MSVC libs locally → CI in M6); AdapterDesc layout assert; README double blank line; CSV/script CRLF
- M2 planning started in parallel: architect-m2 (opus) writes docs/windows/plans/M2-tabs-splits-windows.md
- M2 plan: architect-m2 commits 1dabe2c11 + 5a622aed5 (owner decisions: tray Task 28, WT tab-close Task 29, tab tear-off Tasks 30-32); 35 tasks / 14 waves
- Task 30b: impl-30b-opus DONE: no Ghostty defect — msys2-runtime 3.6.9 write_normal drops the last byte of every 32 KiB block (_sys_mbstowcs NUL slot) before ConPTY; type/PowerShell lossless; e2e stream-integrity 50 MB RF 0 mismatches; RF throughput 9.1 MB/s (cat). Tests added (slicing boundaries, 50 MB overlapped pipe, ConPTY 1 MB)
- Task 30b: review clean; land CONFLICT in test/windows/README.md (Task 30 section) → impl-30b-opus rebasing (Ruling: keep both sections)
- Task 30b: minor (deferred): README states msys2 loss "affects any console host" — inferred from source, verify in Windows Terminal or soften; record Debug runtime of the 50 MB test; ConPTY test logs mode 9001 warn; late-conhost-flush timing sensitivity
- Task 30b: rebased onto windows by impl-30b-opus (README merge kept both sections); Ruling: docs-only conflict resolution verified by lead diff, no re-review — cost if wrong: README wording
- Task 30b: complete (landed)
- Final review M1 → final-review-m1 (opus), range cec8b92f1..e96668c19
- Final review M1: ready with fixes — 0 Critical, 2 Important (I1 quit without needsConfirmQuit; I2 no Linux compile proof of core changes), 6 Minor. Report: final-review.md
- Ruling: fix wave = I1 + I2 (Linux cross-compile x86_64-linux-gnu -Dapp-runtime=none; fix any non-Windows breakage) + Minor: close Command.pid process handle on Windows + docs/windows/CHANGELOG.md M1 section — cost if wrong: one extra wave
- Ruling: upstream rebase deferred to M2 Wave 0 (before the first M2 task) — milestone-close rebase in SPEC §17 — cost if wrong: bigger conflicts later
- Final review M1: fix wave addressed (I1 quit confirm 4f4816248, process handle 538506c09, CHANGELOG 9f3dbb5ad, Linux build proof); re-review clean; changelog wording fixed by lead (docs)
- M1 COMPLETE
