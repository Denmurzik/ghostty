# M6 acceptance — Windows port v1.0

Date: 2026-10-29. Release candidate: `1.3.2-dev-win.1`, built from `f904ba62c` by `dist/windows/release.ps1 -N 1 -V1 -Arm64TestExe` on the owner's machine (local release path, R-M6-6). Tag: `win-1.3.2-dev-1`, published as a GitHub pre-release.

## Build and package (release.ps1, all 9 steps)

- Unit tests ("upstream tests on Windows" = unit group 3's four filters, per the plan):
  - group 1 (win32): 640/641 passed, 1 skipped, 0 failed
  - group 2 (windows, tmux shim, Exec, d3d11): 355/356 passed, 1 skipped, 0 failed
  - group 3 (terminal, config, input, font): 3653/3687 passed, 34 skipped, 0 failed
  - tmux.exe shim: 37/37 passed (fresh run in a separate cache; the release script refuses cached runs without recorded counts)
- x64 (msvc) and arm64 (`aarch64-windows-gnu`, R-M6-11) ReleaseFast builds with `-Dstrip=false`, version resources in both exes.
- Artifacts: portable zip, symbols zip and per-user Inno Setup installer for each arch, `SHA256SUMS.txt`, release notes.
- Privacy scan (user name and profile path, UTF-8 and UTF-16) clean on every staged file, PDB and installer; third-party notices check OK on both arches; bundled ConPTY (`conpty.dll`, `OpenConsole.exe`) pinned SHA-256 and Microsoft signatures valid.
- Imports: no `winhttp.dll`, no `dbghelp.dll` in ghostty.exe; tmux.exe imports kernel32/ntdll/advapi32 only.

## End to end on the RC

- `E2E -Milestone all` against the RC exe (first RC build, `58c4afab8`): 97 PASS, 6 FAIL, 4 SKIP. Triage (`.superpowers` report `rc-e2e-report.md`):
  - transparency: product bug (a window created opaque, reloaded translucent, kept one dim hwnd frame under the composition visual; ReleaseFast only, pre-existing) — fixed in `f904ba62c`; the RC was rebuilt from it.
  - update-check, term-terminfo: scenario drift for a stamped portable exe — fixed.
  - scrollbar: flaky scenario (5/5 then 2/3 on reruns).
  - input-latency, tui-latency, tmux-cli: frame-bound latency tails on a 60 Hz display and process-spawn noise; same on a source build of the same commit (known limits below).
  - device-lost/recover SKIP: ReleaseFast does not simulate device loss (expected); m3-shots SKIP: no evidence dir.
- Rebuilt RC (`f904ba62c`): transparency, update-check, term-terminfo, package-portable, installer-test, explorer-cli, prompt-marks, new-tab-white-flash, close-idle-prompt, opacity-blur — PASS; scrollbar 2/3.
- installer-test on the test setup built from the RC zip: blocked silent setup exit 7 and uninstall exit 1 while Ghostty runs, install / upgrade (InstallDelete) / uninstall with `--only-this-exe`, real HKCU unchanged.
- package-portable on the RC zip: stamped version, 819 themes, non-ASCII folder, OpenConsole from the package folder, Mark-of-the-Web set, no writes, no leftover processes.
- vt-smoke against the RC exe: 15 cases match 100 %; kitty-image, underline-colors and wide-cjk SKIP (no 96 dpi reference yet).

## Measurements (M5 rows in docs/windows/*-baseline.csv, ReleaseFast)

One surface 66.4 MB private (M4 72.1 MB); key echo ghostty-owned p95 4.3–5.6 ms on a quiet desktop; window shown in 537 ms; tmux.exe peak 0.9 / 4.1 MB, wall p95 ≤ 40 ms; release build peak memory 4.9 GB (`-MinFreeGB 7`).

## Known limits accepted for v1.0 (rulings)

- Latency tails are frame-bound on a 60 Hz display: tui-latency and input-latency ghostty-owned p95 exceed the 6 ms gate (p50 ≈ 1 ms); split-many teardown borderline at 100 ms on ReleaseFast; tmux-cli spawn p95 over 50 ms from process-start noise.
- `windows-conpty = auto`: Git Bash/MSYS2 programs run on the inbox ConPTY (the bundled one loses the first key after a resize there), so Kitty graphics and SGR 58 are not available in Git Bash.
- Unsigned builds (SmartScreen "Unknown publisher"; not supported with Smart App Control on); per-user installer only; ARM64 unit tests are an owner check on a device.
- The installer's interactive Retry click while Ghostty runs is checked by hand only (the silent abort paths are covered by installer-test).
- claude-team.ps1 against the RC was not run; the tmux shim was validated against real Claude Code runs in M4 and its unit and replay tests pass on the RC.

## Owner sign-off

Owner instruction (2026-10-28): carry M5 and M6 through to the published pre-release without waiting. The owner's manual checks of § M6 exit checklist remain open and are listed in the release notes' known gaps.
