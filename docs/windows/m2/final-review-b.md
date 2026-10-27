# M2 final review, half B: core, renderer, latency

Range `0305564be..windows` at `72c857715`. Reviewer: final-rev-b (opus). This is a read-only review. It does not cover M3 Task 4/28 or Task 34.9 (`Surface.zig` RecentGrids, `placement.zig`).

Scope: every M2 hunk outside `src/apprt/win32` (24 files, +2608/−322). That covers `Surface.zig`, `App.zig`, `Command.zig`, `pty.zig`, `termio/{Exec,Termio,Options,stream_handler}.zig`, `os/{thread,windows,windows_latency,windows_cmdline,open,main}.zig`, `config/{Config,command}.zig`, `build/SharedDeps.zig`, `renderer/{generic,Thread,D3D11}.zig` and `renderer/d3d11/{Device,Frame,SwapChain}.zig`. Where the apprt integrates with this code I read `win32/{Tab,Window,util,instance,link_policy,actions/app_actions}.zig`.

Evidence I produced myself:
- Targeted unit tests under the test-lock, all passing: `d3d11 device`, `spawn_config`, `win32 link`, `untrusted links`, `d3d11 pacing`, `termio renderer wakeup`, `killChild`, `closing the pseudo console`.
- Linux cross-compile `zig build -Dtarget=x86_64-linux-gnu -Dapp-runtime=none` under the test-lock: exit 0. The core hunks still build off Windows. macOS was not checked (no CI).

## Strengths

- **The core changes are small, duck-typed and neutral on other platforms.** The renderer additions all use the existing `@hasDecl(GraphicsAPI, …)` pattern: `waitFrameSlot`, `isLost`, `frameFailed`, `dumpWakeMs` and `Device.acquire/shutdown`. Metal and OpenGL compile them away. Thread spawns go through `os/thread.zig` `spawn_config`, which is `.{}` everywhere except Windows. The Linux build passes.
- **Two upstream-worthy bug fixes:**
  - `Termio.changeConfig` sends the mode-2031 report directly (`Termio.zig:511`). Previously `StreamHandler.changeConfig` queued it into the IO mailbox from the IO thread, its only reader, which deadlocks when the mailbox is full.
  - Termio, StreamHandler and Options now hold `*xev.Async` instead of a by-value copy (`Options.zig:35`). With IOCP the wakeup state lives inside the struct, so a copy notified nothing. This was the #1 latency cause.
- **The 34.1 RAM fix is correct and well explained** (`os/thread.zig:17`). Zig 0.17 passes `stack_size` as the commit size on Windows. A 64 KiB commit keeps the 16 MiB reserve from the PE header. The unit test checks both the commit and the reserve.
- **Shared-device lifetime is sound** (`d3d11/Device.zig`):
  - `refs`, `current`, `next_generation` and `lost_seen` change only under `registry_mutex`.
  - `markLost` flips `lost` before taking the mutex, which is idempotent and tolerates a concurrent `acquire`.
  - A silent removal while nothing holds the device (tray, no window) is caught by the `alive()` probe in `acquire`.
  - The last `release` frees a lost generation. `App.deinit` drops the registry ref after all surfaces are gone.
  - A fake-factory concurrency test balances creates and destroys.
  - `D3D11.init` cannot fail, so the `acquire` in `Surface.init:590` cannot leak through `Renderer.init`'s errdefer.
- **The frame-slot wait is safe across threads** (`D3D11.zig:354`):
  - It waits without the context lock on a *duplicated* waitable handle.
  - It books the result only when the chain `serial` still matches, so a concurrent `dropSwapChain` cannot be double-counted or reach a closed handle.
  - It runs before `draw_mutex`, so a sync draw never waits behind it.
  - The second call from `drawFrame` after `renderCallback`'s call is a cheap no-op: either nothing is pending, or the chain is already idle after a 100 ms timeout. That rules out a 200 ms double stall.
- **Re-parenting is handled narrowly** (`D3D11.zig:245`, `Frame.zig:128`):
  - The chain is recreated only on `ComFailure` *and* a generation bump.
  - The generation is read before the present, so a bump that lands during the present stays unaccepted.
  - `dropSwapChain` calls `clearState`+`flush` before release. That avoids E_ACCESSDENIED on recreate for the same HWND.
- **The two-phase teardown is clean and upstreamable** (`Surface.zig:841` `stopRenderThread`/`stopIoThread`): idempotent flags, renderer joined before the IO stop is notified, and `deinit` behaviour unchanged for upstream callers.
- **The open_url policy is layered.**
  - The apprt `open_url` always returns true, so the core never falls back to `os.open`. `os/open.zig:27` also refuses `unknown`/`osc8` on Windows as a backstop.
  - `link_policy.classify` allows http/https with a host, plain `mailto` without `attach`, and local drive paths or `file://[localhost]/C:/…` for reveal-only, with percent-decode re-checks, device-name, ADS, wildcard and bidi rejection.
  - UNC, network `file://` and all other schemes are refused.
  - The trusted `.text`/`.html` kinds are produced only by `Surface.zig:5996`, for Ghostty-written files.
- **The process semantics change (Task 29/34.8) is coherent.** `killChild` ends only the direct child, and `Subprocess.stop` then closes the pseudo console so `CTRL_CLOSE_EVENT` ends the attached clients (`Exec.zig:1187`). A real ConPTY test pins this behaviour. The behaviour matches Windows Terminal, as the ledger ruling requires.

## Issues

### Blocker

None.

### Important

**I1. Diagnostic env vars are honoured in Release and in elevated processes: DLL load, arbitrary file truncate, screen dump**
- **Where:**
  - `os/windows.zig:599-655` (`GHOSTTY_WIN32_CONPTY_DLL` → `LoadLibraryExW` of any path; `GHOSTTY_WIN32_CONPTY_FLAGS`).
  - `os/windows_latency.zig:281-298` (`GHOSTTY_LATENCY_TRACE` → `createFileAbsolute(path, .{})`, which truncates).
  - `d3d11/Frame.zig:206` (`GHOSTTY_D3D11_DUMP` → `createDirPath` plus BMPs of every frame).
  - `D3D11.zig:154` (`GHOSTTY_D3D11_PACING_LOG`).
  - `Device.zig` `applyEnv` (driver/debug layer).
- **Failure scenario:**
  1. A medium-integrity process (or a careless script) writes `HKCU\Environment\GHOSTTY_WIN32_CONPTY_DLL=C:\Users\x\AppData\Local\Temp\a.dll`. No elevation is needed for this.
  2. The user later runs Ghostty with "Run as administrator". UAC builds the elevated environment from the user profile, so the variable is present.
  3. `Pty.open` → `conpty()` loads `a.dll` into the high-integrity process. The user consented to Ghostty, not to that DLL.
  4. The same channel makes an elevated Ghostty truncate any file (`GHOSTTY_LATENCY_TRACE=C:\Windows\System32\drivers\etc\hosts`).
  5. It can also continuously write the admin session's screen contents into a user-readable directory (`GHOSTTY_D3D11_DUMP`).
- **Why it matters for M2:** M2 deliberately built an elevation boundary for IPC (Task 5/20: separate `-a-` pipes and integrity checks). These variables bypass it.
- **Secondary problem:** `Exec.zig:679` strips only the latency and ConPTY variables from the child environment. `GHOSTTY_D3D11_DUMP/PACING_LOG/DRIVER/DEBUG/SIMULATE_DEVICE_LOST` leak into shells, and from there into any Ghostty launched from inside the terminal. That includes a nested e2e instance dumping into the outer harness's directory.
- **Fix (now, about 40 lines):**
  1. Move `instance.isElevated` (`apprt/win32/instance.zig:98`, already cached) into `src/os/windows.zig`.
  2. Add one `diagnosticEnv(alloc, name) ?[]u8` helper that returns null when the process is elevated.
  3. Route all of the reads above through it.
  4. Additionally make `GHOSTTY_WIN32_CONPTY_DLL` Debug-only. Task 40 is N/A, so nothing in Release needs it. While there, `FreeLibrary` the module when `GetProcAddress` fails (Task 36 deferred minor).
  5. Strip every `GHOSTTY_D3D11_*` variable in `Exec.zig:679`.
  6. Add a unit test that the helper returns null when `isElevated` is forced true.

### Minor

**M1. A dead job object and PE-subsystem code remain after the `killTree` → `killChild` change**
- **Where:** `Command.zig:364-470` (`CreateJobObjectW` + `PROC_THREAD_ATTRIBUTE_JOB_LIST` for every child), `:475` `jobProcessIds`; `os/windows.zig:513-570` (`IMAGE_SUBSYSTEM_*`, `IsProcessInJob`, `QueryFullProcessImageNameW`, `peSubsystem`).
- **Problem:** Production code no longer reads any of this; only tests do. Every surface pays a job handle and the attribute-list setup for nothing, and future readers will assume the job is used for cleanup.
- **Fix:**
  - If no M3 task names a consumer (process list for confirm-close, for example), delete the job creation, `jobProcessIds`, `peSubsystem` and its test, and keep `closeJob` out.
  - Otherwise, add one line naming the planned consumer on the `job` field.

**M2. The frame pacer allows 2 pending presents while the swap chain's maximum frame latency is 1** (`SwapChain.zig:261`, Task 37 deferred minor)
- **Failure:**
  1. A sync draw on the UI thread presents next to the render thread (live resize), so `pending` reaches 2.
  2. The waitable can hold at most a count of 1, so one signal is lost.
  3. The render thread's next `waitFrameSlot` blocks until the 100 ms timeout, unless the chain has already been idle for 50 ms.
- **Impact:** At most one dropped frame interval per occurrence, during resize only. The latency gates were met without fixing this, so it is not urgent.
- **Fix:** Cap at the configured frame latency (`setMaximumFrameLatency(1)` → a `max_pending = 1` constant shared with `init`). Re-measure b1/b3 in the same change.

**M3. Core guards for stopped threads are partial** (`Surface.zig:1836`, `:4903`)
- **Current state:** `threads_stopping` guards only `updateConfig` and `colorSchemeCallback`. Other UI-thread entry points still push to the renderer and IO mailboxes with `.forever`, for example `Surface.zig:982/990/1539`, `sizeCallback` and `focusCallback`.
- **Failure:** In the window between `stopRenderThread` and `deinit`, `serviceSentMessages` (`util.zig:28`) can dispatch a cross-thread *sent* message to a surface HWND. If more than the mailbox capacity is queued, the UI thread hangs forever. Today only top-level windows get the broadcasts that matter, and `Window.zig:1086` drops them during teardown, so this cannot happen at HEAD.
- **Fix:** Add a doc comment on `stopRenderThread` stating the contract ("after this, the runtime must not call any Surface callback except `deinit`"). Alternatively, turn the `.forever` pushes into `.instant` when `threads_stopping` is set. Defer to M3.

**M4. Windows-only latency marks sit in shared core files**
- **Where:** `renderer/generic.zig:1435,1843`, `renderer/Thread.zig:486,585`, `termio/Termio.zig:702`, `termio/Exec.zig:504,1875,1879`.
- **Problem:** Each call site is comptime-gated or a one-atomic-load no-op, so behaviour is neutral. Upstream would still not take `@import("../os/main.zig").windows_latency` calls in generic files, and every upstream merge re-touches these lines.
- **Fix:** Collapse them into one `renderer.trace`/`internal_os.trace` facade that compiles to empty inline functions off Windows, with one import per file. Alternatively, record in DECISIONS that the tracer stays fork-only. Defer to M3, together with the upstream-sync task.

**M5. `windows-single-instance = true` behaves exactly like `detect`** (`apprt/win32/instance.zig:176`, `config/Config.zig:3811`)
- **Doc problem:** The doc says `true` is "Like `detect`; a command is never forwarded". `detect` never forwards a command either.
- **Second doc gap:** The `detect` text does not say that an `initial-command` in the config prevents forwarding.
- **Fix (now, doc only):** Either describe `true` as an alias kept for parity with `gtk-single-instance`, or drop the value before it ships (M2 is its first release). Add the `initial-command` caveat.

**M6. `swap_chain_failure_logged` never resets** (`D3D11.zig:275`)
- **Problem:** After one logged create or present failure that later recovers, every later failure of that surface is silent, which makes field logs misleading.
- **Fix:** Reset the flag in `presentSucceeded`. Defer to M3.

**M7. `threadExit` releases the chain without `clearState`, unlike `dropSwapChain`** (`D3D11.zig:190`, Task 30 deferred minor)
- **Impact:** None at HEAD, because the HWND is destroyed after the join and is never reused. It is an inconsistency, and two teardown paths are a trap if the M3 composition mode reuses a window.
- **Fix (now, one line):** Call `self.dropSwapChain()` under the lock.

## Upstreamability of core hunks

| Hunk | Verdict |
|---|---|
| `os/thread.zig` + `spawn_config` at 6 spawn sites | Upstreamable (real Zig 0.17 Windows commit-size issue); neutral elsewhere |
| `Surface.stopRenderThread/stopIoThread` + `threads_stopping` | Upstreamable (generic multi-surface teardown speed-up) |
| `Termio`/`StreamHandler`/`Options` `*xev.Async` | Upstreamable bug fix (copies of `xev.Async` are wrong on IOCP) |
| `Termio.changeConfig` 2031 report | Upstreamable bug fix (self-deadlock on a full mailbox) |
| `os/open.zig` untrusted kinds on Windows | Upstreamable |
| `config/command.zig` unbounded `formatEntry`, `windows_cmdline.writeCommandLine` | Windows-only, upstreamable |
| `generic.zig` `waitFrameSlot`/`isLost`/`frameFailed`/`dumpWakeMs` hooks, `Thread.renderCallback` wait | Upstreamable in shape (duck-typed); depends on the D3D11 backend landing |
| `Surface.init` `Device.acquire` branch, `App.deinit` `Device.shutdown` | Same; neutral |
| `Command.killChild` / Exec stop closes the pseudo console | Windows-only; matches upstream intent |
| `pty.zig` `conpty()` indirection, `os/windows.zig` ConPty loader | **Fork-only diagnostic**: drop the DLL path or make it Debug-only (I1) |
| `windows_latency` marks in generic/Thread/Termio/Exec | **Fork-only** (M4) |
| `Config` `windows-single-instance`, quit-after-last-window doc | Windows-only; doc fix (M5) |
| `SharedDeps` win32 system libs only for win32 importers | Upstreamable (lib-vt consumers no longer link user32 etc.) |

## Deferred minors triage (my area)

| Ledger item | Decision |
|---|---|
| T36: single global open sample / per-surface (c2) | Drop (tracer is diagnostic; surface id already tags samples) |
| T36: no `FreeLibrary` on `GetProcAddress` failure | **Fix now** with I1 |
| T36: unbalanced `timeEndPeriod` in tui-latency.ps1 | Done (5b1e6eee6) |
| T36: weak "disabled marks are no-ops" test; Debug rows; (c2) unmeasured | Drop |
| T37: Pacer cap 2 vs latency 1 | M3 latency/RAM pass (Task 35 follow-up) as M2 above, with re-measure |
| T37: `idle_ns` fixed 50 ms; poll syscall in idle | Drop (idle CPU measured 0.05–0.10 % RF, 34.12) |
| T37: wheel counted twice in probe stats; b3 vim gate flake; no mixed 120+40 test | Drop (test tooling; b3-vim is record-only by ruling) |
| T37.1: tautological loop test; add `StreamHandler`/`Options` `@FieldType` asserts | **Fix now** (two lines in `Termio.zig:871`); "Windows-only" part is moot: the test runs everywhere |
| T37.1: report omits mailbox.zig:33 verdict | Drop |
| T37.2: `DuplicateHandle` mid-file in kernel32.zig | Drop |
| T37.2: idle CPU not measured | Done (34.12) |
| T34.3: kitty delay postpones trailing dump; sync/draw_now throttled frames arm no timer; no backoff | Drop (dump is harness-only) |
| T4: `before_write` test hook in production `Dump` | **Fix now**: field type `if (builtin.is_test) ?Hook else void` (`Frame.zig:192`) |
| T4: `last_width/height` set before readback; same-size throttle asserts width only; `complete(false)` twice | Drop |
| T30: `threadExit` without `clearState` | **Fix now** (M7) |
| T30: no Frame-level retry test; WARP readback after re-parent | M3 (with composition swap chains) |
| T30: e2e render/resize pending | Verify in Task 33 batch (lead) |
| T34.4: mailto header name not whitespace-trimmed (`%20attach=`) | **Fix now**: trim ASCII whitespace after `percentDecode` in `link_policy.zig` `hasAttachment` |
| T34.4: `C:\` reveal keeps the trailing backslash | Drop (reveal only; explorer gets a harmless odd arg; no execution path) |
| T34.4: rundll32 branch for `.text/.html` in `os/open.zig` | Keep (reachable for `app-runtime=none`; trusted kinds only) |
| T29: JobTree test slots not nulled after `CloseHandle` | Fix now (test hygiene) or fold into M1 deletion |
| T29: no unit test of `Subprocess.stop` ordering | Drop (covered by the ConPTY close test + e2e close-tree) |
| T29: WT-as-default-terminal makes `start cmd` open a WT tab | Drop (environmental; documented) |
| T15: `formatEntry` extraction | Accepted; no open minor |
| T1: advapi32 `HKEY_CURRENT_USER` zero-extended | Not in my half (pkg/win32, apprt users): final-rev-a |

## Declined to judge

- GUI behaviour of device loss (`device-lost` e2e is Debug-only and pending the batch).
- Actual DXGI semaphore counts behind M2. I reasoned from the documented waitable semantics and did not measure them.
- macOS compile.

## Verdict

**Ready with fixes.** No blocker. Before M2 is called done:
- **Must fix:** I1, because it is a security issue M2 explicitly scoped: diagnostic env vars must not reach an elevated process, and the ConPTY DLL override must be Debug-only.
- **Small, fold into the same wave:** M5 (doc), M7, and the four "fix now" ledger items.
- **Defer:** M1–M4 and M6 can go to M3 (M1 needs a keep/delete decision first).
