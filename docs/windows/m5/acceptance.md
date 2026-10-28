# M5 acceptance record

Code under test: `windows` at `1e4912c37` (code unchanged since `264869ba5`); the budget rows were measured on a ReleaseFast
build of `8b7e2d511` on 2026-10-29, the e2e passes on Debug builds of `efe573739` and `15e19d1a2`. Source: the ledger
`.superpowers/sdd/M5-windows-extras/progress.md`, the e2e logs `e2e-m5-debug-1.log`, `e2e-m5-rf-1.log`, `e2e-all-debug-1.log`
and `e2e-all-debug-2.log` in that directory, the final review A/B/C, `docs/windows/{ram,latency}-baseline.csv`, the CHANGELOG
"M5" section and SPEC §17 M5.

Status: **done, accepted with known limits and owner checks pending**.

- Two budget rows miss their goal and are accepted as limits (below): `tui-latency` owned p95 and the `split-many` teardown.
- The owner's manual checks (exit checklist 8) are open.
- The per-feature RAM rows were not measured (`measure-ram.ps1` has no recipes for them).

## Exit checklist (plan `docs/windows/plans/M5-windows-extras.md`, "M5 exit checklist")

| # | Item | Result | Evidence |
|---|---|---|---|
| 1 | Builds and unit tests | PASS | Debug and ReleaseFast build with the compiled terminfo. `win` filter 872/876 (4 skipped) after the final fix wave, `win32 ` 636/637, unit total 986 pass / 5 skip at the fix wave. `-Demit-lib-vt` and the Linux recipe build; ARM64 cross-build (`aarch64-windows-gnu`) PASS on 2026-10-29. |
| 2 | e2e | PASS with documented limits | `E2E -Milestone M5` Debug: 15 PASS, 2 FAIL (`right-click` copy, `osk` state), both scenario-only and fixed in 19.n batch 4 (`osk` and `right-click` PASS twice); ReleaseFast: 16 PASS, 1 FAIL (`osk`, same fix). `E2E -Milestone all` round 1 (Debug `efe573739`): 84 PASS, 20 FAIL, 1 SKIP, nine clusters, fixed in `6301b57a6` and the fix wave (COM `0x80070003` in the jump list, dialogs timing, proxy icon, `windows-conpty = auto`). Round 2 (Debug `15e19d1a2`): 99 PASS, 5 FAIL, 3 SKIP (package, setup and evidence inputs not set). Of the 5: `prompt-marks` (pwsh repeated exit code, fixed `8b7e2d511`, PASS twice), `new-tab-white-flash` (1 of 65 frames white, fixed `4799a5a15`, Debug 5/5, ReleaseFast 5/5); `split-many`, `stream-integrity` (50 MB, Debug) and `tui-latency` are the limits R-M5-15, 16 and 18 below. `dpi-sim` passes on the current Debug. |
| 3 | Every M5 feature has evidence | PASS | Unit tests plus a scenario or scripted check per row of the feature checklist. The update check passed against the fake release server (`update-check`: newer, same, HTML, 403, redirect, silent server, one toast per release). |
| 4 | Budgets | PASS with misses | One surface 66.1-66.7 MB private bytes, ReleaseFast, 3 runs (M4: 72.1). Key echo (Ghostty-owned p95, 60 Hz) 4.3-5.6 ms, gate 6 ms. Startup 537 ms (gate 1500 ms). `tmux.exe` peak 0.9 MB (`display-message`) and 4.1 MB (`load-buffer`), wall p95 within 40 ms. `ghostty.exe` imports neither `winhttp.dll` nor `dbghelp.dll`; `tmux.exe` imports kernel32, ntdll and advapi32 (the SID check). Misses: see limits. |
| 5 | Owner safety | PASS | `explorer-cli` asserts the owner's real keys are unchanged before and after; no scenario log names `api.github.com` and every `update: fetching` line names `127.0.0.1`; no WSL distro was started; dumps are scanned for the pty marker and hold none. |
| 6 | Feature checklist | PASS | M5 rows are `done`, `manual` or a documented gap (`docs/windows/feature-checklist.md`, `parity-audit.md`); the shell-integration row is closed. |
| 7 | SPEC | PASS | §17 M5 marked accepted; §18 holds R-M5-1…14 with 9a and 12a and the limit rulings R-M5-15…18; §8.5, §10, §11, §12 and §13 amended. |
| 8 | Owner manual checks | **PENDING** | See below. |
| 9 | Changelog | PASS | CHANGELOG "M5": the keys (`windows-conpty`, `windows-tmux-external`, `auto-update`, `auto-update-channel`, `undo-timeout`, ...) and the known gaps. |

## Final review

`final-review-{A,B,C}.md` in the ledger directory, over `c791e5735..windows`:

- A: 0 critical, 1 important (undo restored into the hidden quick terminal and focused it), minors (a parked split still renders; restore after a DPI change).
- B: 0 critical, 1 important (the pwsh integration nulled `$LASTEXITCODE`), ten minors.
- C: 1 critical (`release.ps1` passed the per-arch ConPTY directory in the wrong form), 3 important (an elevated e2e would write the real HKCU, three scenarios lacked the clipboard mark, the MSYS2 first-key caveat was undocumented), minors.

One fix wave (seven commits `b834d5ac9..124204b3d`) and a scoped re-review: all ADDRESSED. Accepted residual: users who only run
standalone processes get no update notices.

## Known limits (rulings)

- **tui-latency (R-M5-15).** Owned p95 14-16 ms against the 6 ms gate. The panel runs at 60 Hz and the path is bound by one frame (16.7 ms); the M3 acceptance at 120 Hz already measured 9.7 ms on `b2-vim`, so the miss predates M5.
- **split-many teardown (R-M5-16).** 112 ms against 100 ms in one of two ReleaseFast runs; Debug measured 71-164 ms. The gates are 100 ms on ReleaseFast and 150 ms on Debug (`264869ba5`).
- **`windows-conpty = auto` (R-M5-17, default).** The bundled console loses the first key after a pty resize in MSYS2/Cygwin programs (a CSI 6 n round trip; 0 of 36 lost with the inbox console). `auto` uses the inbox console for MSYS2 and Cygwin programs and the bundled one otherwise, decided when the pty opens, so Kitty graphics and SGR 58 do not work in Git Bash. `windows-conpty = bundled` forces it at the risk of lost keys. A hold-back of input was ruled out by timing evidence.
- **50 MB stream on Debug, per-feature RAM rows (R-M5-18).** `stream-integrity` has never finished on a Debug build since M1 (not a regression); ReleaseFast passes the 50 MB in 42 s. Per-feature RAM rows (profiles menu, update check, undo parking, external tmux, crash handler) are not measured because `measure-ram.ps1` has no recipes for them; the one-surface and `tmux.exe` rows are.
- The gaps of the CHANGELOG "M5" section stand (Explorer entry only under "Show more options", no automatic secure input, cmd without exit codes, ...).

## Pending for the owner (exit checklist 8)

Each line is PASS / FAIL once the owner has run it.

- [ ] `ghostty.exe +install-explorer-integration`; "Open Ghostty here" on a folder, a folder background and `C:\` under "Show more options" opens there; `+uninstall-explorer-integration --all` removes everything.
- [ ] The pinned jump list shows New Window, New Tab and the profiles (also with recent items off); a WSL profile opens the distro in `~`.
- [ ] Right-click `+`: pwsh and a WSL distro open; the palette entries work with one tab.
- [ ] A real update toast against a test `win-…-N` release (or `auto-update = off` respected); its click opens the release page.
- [ ] Secure input on: OBS or Snipping Tool shows the window and the palette black; a copy is absent from Win+V history.
- [ ] `ctrl+shift+z` after closing a tab by mistake brings it back with its shell.
- [ ] The touch keyboard appears on a touch or tablet-mode machine (or N/A).
- [ ] With `TERM=xterm-ghostty` in Git Bash, `vim`, `less` and `htop` look right; `wsl -e sh -c 'echo $TERM; tput colors'` shows a usable TERM.
- [ ] With `windows-tmux-external = true` and the Ghostty directory on PATH, Claude Code started in Windows Terminal opens its teammates in a Ghostty window.
- [ ] The GUI references for the bundled console (`kitty-image`, `underline-colors`) with `windows-conpty = bundled` in a non-MSYS2 shell.
