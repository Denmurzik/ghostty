# M2 acceptance record

Commit under test: 4df054888 (`windows`), worktree build, Intel Arc iGPU (hardware adapter, 120 Hz), 175 % scaling,
2026-10-27. Evidence: `%TEMP%\m2-ev-rf` (ReleaseFast), `%TEMP%\m2-ev-dbg` (Debug), `%TEMP%\m2-acceptance` (screenshots).

## Exit checklist

1. **PASS** builds and tests: Debug `zig build -j6` ok; ReleaseFast (`--prefix zig-out-rf`) ok; `pkg/win32` 26/26; `-Dtest-filter="win32 "`
   247 pass, 3 skip, 3 runs green (runs 2 and 3 were cache hits of run 1); `"d3d11 "` 80/80; `"windows latency"`
   (`-Dapp-runtime=none`) 83/83; `config` 278 pass, 4 skip; Linux `-Dtarget=x86_64-linux-gnu -Dapp-runtime=none` and
   `-Demit-lib-vt` build. ARM64 `-Dtarget=aarch64-windows-gnu`: **FAIL (recorded, not gating)**: two `@ptrCast increases
   pointer alignment` errors, `pkg/win32/comctl32.zig:99` and `src/os/windows.zig:712` (GetProcAddress results cast to
   function pointers; MSVC ARM64 is checked in the M6 CI).
2. **PASS** (not re-run; the classification test is part of the 247 `win32 ` tests).
3. **PASS with notes** `E2E -Milestone all`, 53 scenarios plus the new `m2-acceptance`.
   - ReleaseFast: every scenario PASS, `device-lost` SKIP (needs a Debug exe). `close-while-streaming` failed once
     (ghostty still running 15 s after the window closed while streaming), passed alone on the rerun (70 ms): flaky, not
     reproduced; keep an eye on it (task 34.6 area).
   - Debug: every scenario PASS, including `device-lost`, `split-many`, `close-while-streaming`. `stream-integrity` at the
     default 50 MB times out on Debug (documented, 2 MB PASS with `GHOSTTY_E2E_STREAM_MB=2`). `input-latency` was FLAKY
     once (target lost the foreground), then PASS.
   - Latency, ReleaseFast, 3 quiet runs (per-gate p95 median): key-echo owned 1.3 ms (5.2 / 1.2 / 1.3), b1-less 1.3,
     b2-less 3.2 (0.4 / 3.2 / 6.4), b3-less burst total 14.7 ms (14.7 / 23.2 / 6.5), b2-less-mouse 0.4, b1-vim 3.4
     (7.0 / 2.8 / 3.4), b2-vim 0.6 (0.6 / 0.5 / 9.7), output-idle total 1.0 ms: all medians within the gates; single
     runs miss (b1-vim 7.0, b2-less 6.4, b2-vim 9.7 ms, owned > 6 ms) because of outliers (max 13..29 ms).
   - Under background load of 9-19 % CPU (other sessions building on the same machine) three further RF runs failed
     key-echo owned (14.8 / 15.1 / 15.8 ms) and several tui gates (15-24 ms): load-sensitive Ghostty-owned stage
     (renderer-thread wake), see product bug 1.
4. **PASS (e2e) / OWNER (the rest)** `single-instance`, `ipc-cli`, `quit-after-last`, `windows-multi` PASS on RF and Debug;
   class isolation holds (e2e instances use their own class). The 1.5 s second-window timing is asserted by the scenario.
   The elevated `-admin` pipe is covered by unit tests only.
5. **FAIL (2 of 4 rows), owner decides** RAM, ReleaseFast, hardware adapter (`docs/windows/ram-baseline.csv`):

   | row | MB private | per unit | gate | result |
   |---|---|---|---|---|
   | one-surface | 69.1 | | <= 80 | ok |
   | tabs (10 x new_tab) | 125.6 | +5.7 per tab | <= +10 | ok |
   | splits (10 x new_split) | 129.3 | +6.0 per split | <= +10 | ok |
   | windows (4 x new_window) | 140.2 (rerun 140.1) | +17.8 (+17.8) per extra window | <= +15 | **over** |
   | close-10 (before 68.8) | 81.2 (rerun 78.5 vs 68.8) | +18.0 % (+14.1 %) | <= +10 % | **over** |
   | zero-windows | 63.1 | | recorded | |

   The G1 levers were applied in Task 34.1; both rows are still over, reproduced twice. The +80 MB after the first 16-pane
   cycle was accepted earlier as pre-existing; close-10 re-measured in its own terms is +12.4 / +9.7 MB absolute.
   Idle CPU one-surface, 30 s (`m2-acceptance`): 0.58 s of CPU = 1.9 % of one core (0.09 % of 22 logical CPUs).
6. **PASS, needs the lead's look** screenshots in `%TEMP%\m2-acceptance` (see below), inspected by me.
7. **PASS on medians, see item 3** latency gates; Task 40 is N/A (ledger); rows for the three scenarios (3 quiet RF runs
   and one Debug run) appended to `docs/windows/latency-baseline.csv`.
8. **OWNER** manual checklist: not run.
9. **LEAD** upstream rebase and the owner changelog.

## Screenshots (`%TEMP%\m2-acceptance`)

One window, 3 tabs, the middle tab split into 4 panes (left pane, right column of 3), cmd shell:
`m2-acceptance-{dark,light}-{96,144,192}-window.png` (+ `-dump.png` frame dumps), `m2-acceptance-maximized-window.png`,
`m2-acceptance-fullscreen-window.png`, drop mid-drag and dropped (`drop-files-gitbash-middrag-window.png`,
`drop-files-gitbash-dropped-window.png`, from the RF evidence). The window size is the 175 % machine's default window
squeezed to the simulated DPI, so the 96 dpi shot is small (661 px wide).

Looks right: 1 DIP dividers (thin, light), tab strip with the active tab lifted and the close button on the active tab,
Mica tint visible in the light strip, text sharp at 192 dpi, fullscreen hides the strip, no drop highlight as on macOS.
Visually off against macOS Ghostty:
- the native always-visible scrollbar (grey arrow and gutter) shows in every pane even with no scrollback; macOS uses an
  overlay scroller (known interim, ledger, M3);
- tabs are not equal width with a centred title like the macOS window tabs (known, M3 polish task);
- at 96 dpi the narrow window clips the 3rd tab title and the + button.

## Product bugs for the lead

1. Key-echo / TUI Ghostty-owned p95 rises to about 15 ms when the machine has 10-20 % background CPU (3 runs); quiet runs 1.2-1.3 ms,
   outliers up to 13-29 ms even when quiet (b1-vim, b2-vim). Renderer-thread wake or priority; the gates only hold on
   a quiet machine.
2. `close-while-streaming` RF: one failure out of two (15 s exit), not reproduced.
3. RAM: window +17.8 MB (> 15), close-10 +14..18 % (> 10 %).
4. ARM64 `@ptrCast` alignment errors at `pkg/win32/comctl32.zig:99` and `src/os/windows.zig:712`.

## Test harness changes in this task

`measure-ram.ps1`: `windows`, `close-10` scenarios; tabs/splits now 10 (were 4). New scenario `m2-acceptance`
(idle CPU, screenshot set). README, SPEC §14 and §17 updated.
