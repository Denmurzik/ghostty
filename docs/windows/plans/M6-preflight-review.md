# M6 pre-flight review

Plan: `docs/windows/plans/M6-release.md` (revision 3, 13 tasks, W1–W4 + G1/G2 + W5, optional Task 12). This is a
read-only review against the owner's binding M6 decisions, DECISIONS "Release" and the v1.0 gate, SPEC §3/§13/§16/§17,
and the code on `windows` at `cb9d3a395`. The plan branch is 5 commits behind it; the only difference in M6 files is
`src/build/GhosttyExe.zig` (7f5ff2096 keeps unwind tables on stripped Windows builds). No builds, tests or GUI runs were
done. Existing outputs (`zig-out`, `zig-out-rf`) were inspected read-only.

Code read: `src/build/{Config,GitVersion,GhosttyExe,GhosttyTmuxShim,GhosttyResources,SharedDeps}.zig`, `build.zig`
(test exe, `test-tmux-shim`), `build.zig.zon`, `dist/windows/ghostty.rc`, `src/apprt/win32/update/{release,Updater}.zig`,
`src/os/windows_explorer.zig`, `src/cli/explorer_integration.zig`, `src/apprt/win32/tray.zig` (end-session),
`src/apprt/win32/App.zig` (tray init), `src/config/Config.zig` (working-directory default, `probableCliEnvironment`),
`src/os/{desktop,resourcesdir}.zig`, `src/termio/shell_integration.zig` (pwsh and MOTW), `test/windows/e2e.ps1`,
`e2e/_common.ps1`, `.gitignore`, `.git/info/exclude`, `.github/workflows/*` (triggers), and Zig 0.17
`std/Build/Step/{Compile,InstallArtifact,Run}.zig`, `compiler/Maker/Step/Run.zig`, `std/SemanticVersion.zig`.

Totals: **1 CRITICAL, 10 IMPORTANT, 19 MINOR.**

What holds up (checked, no finding):
- R-M6-1 is right about today's behaviour: `Config.zig:330-341` panics for any exact tag other than `tip` and `v<zon>`,
  and `GitVersion.detect` uses `git describe --exact-match --tags`. The fall-through to `<zon-mmp>-<branch>+<hash>` gives a
  version without `-win.`, which `release.currentN` reads as a local build.
- The update check matches the scheme: `release.zig` reads `/releases?per_page=20`, skips drafts, counts pre-releases,
  parses `win-<zon>-<N>` with a canonical `N` and compares by `N` only. A `-win.0` rehearsal build is offered `N = 1`.
  Unauthenticated `/releases` never lists drafts, so the draft-then-publish order of R-M6-7 is safe.
- On Windows the default `working-directory` is `home`: `probableCliEnvironment()` returns false on Windows
  (`Config.zig:5488`), so `Config.zig:4910` picks `.home`. "Launch Ghostty" from Inno therefore opens the shell in
  `%USERPROFILE%` even without `WorkingDir` (see MINOR 18 for the process CWD).
- The pwsh integration already ignores Mark-of-the-Web: the script is read and compiled, not dot-sourced
  (`shell_integration.zig:406-410`). A zip extracted from a browser download keeps working.
- The tray window answers `WM_QUERYENDSESSION`/`WM_ENDSESSION` (`tray.zig:224-232`). It exists whenever the instance owns
  its pipe (`App.zig:198`), so Restart Manager can close a running Ghostty during an upgrade.
- The release exes carry no local path. `zig-out-rf/bin/ghostty.exe` and `tmux.exe` contain neither the Windows user
  name nor the repo path, and the Debug exe's CodeView record names only `ghostty.pdb`. The PDBs do leak (CRITICAL 1).

## CRITICAL

**1. The published `-symbols.zip` contains the Windows user name (R-M6-3 lines 203/212-214, Task 4 step 5 line 488, Task 8 step 5, Global Constraints line 60).**
- The plan publishes `ghostty.pdb` (and `tmux.pdb`) as a public release asset. A Zig-built PDB records the absolute
  paths of every object and library it links, including those in the global Zig cache under `%LOCALAPPDATA%\zig`. That
  cache path contains the Windows user name.
- Evidence: the existing Debug `zig-out/bin/ghostty.pdb` contains `C:\Users\<user>\AppData\Local\zig\o\…\compiler_rt.lib`,
  `…\compiler_rt_zcu.obj`, `…\ws2_32.lib` and `…\mswsock.lib` (2 occurrences of the user name, `grep -a -c`). A ReleaseFast
  `-Dstrip=false` PDB links the same compiler_rt and import libs, so it records the same paths. The aarch64-windows-gnu
  build adds libc++/libunwind/MinGW CRT objects, which are also built in the global cache.
- The PDB also holds every source path under the repo (`C:\D\den4ik\Ghostty\…`, `zig-pkg\…`). That is not the Windows
  user name, but it does reveal the owner's local layout, and the owner should decide on it knowingly.
- Nothing in the plan looks inside the artifacts: the privacy rule covers "committed files, reports and release notes"
  only. A public asset is the hardest of these to take back, because mirrors and caches keep it.

Fix:
- `release.ps1` runs both release builds with `ZIG_GLOBAL_CACHE_DIR` set to a neutral path without the user name, e.g.
  `<repo>\.zig-global-release` (git-ignored) or `C:\zc`. It costs one cold rebuild of compiler_rt and the libc++/MinGW
  libs.
- `package.ps1` gains a `privacy` check that scans every staged exe, every PDB and the setup exe for `$env:USERNAME` and
  `$env:USERPROFILE`, in ASCII and UTF-16LE, case-insensitively, and fails with `package: FAIL privacy <file>`. Add it to
  the Task 4 verify list and the Task 9 rehearsal.
- The exit checklist line 1 adds "privacy scan passed".
- Optional, owner's call: build releases from a neutral checkout path (e.g. `C:\src\ghostty`) so that the PDB source paths
  are neutral too.

## IMPORTANT

**2. `zig-out-release\` is not git-ignored, so the preflight refuses the first run and the dirty-tree check refuses every later one (line 81, Task 8 step 1 line 616, R-M6-7 line 271).**
- Line 81 says the default `-OutDir` is "git-ignored by the existing `zig-out*` pattern". There is no such pattern.
  `.gitignore` has `zig-out/` (and `zig-cache/`, `.zig-cache/`, `zig-pkg/`). `zig-out-rf` is ignored only by the owner's
  local `.git/info/exclude:19`. `git check-ignore -v zig-out-release/x` matches nothing.
- So the preflight's `git check-ignore confirms that it is ignored` fails on every run. If an implementer drops that
  check instead, the first run leaves `?? zig-out-release/`. `git status --porcelain` then reports a dirty tree, and
  `release-version.ps1` refuses every later real release (and `-Force` re-run).
- `zig-out-ver` (Task 2 step 1) has the same problem in a worktree.

Fix: default `-OutDir` to `zig-out\release\<version>` (covered by `zig-out/`; `zig build` never cleans `zig-out`). Use
`zig-out\ver` and `zig-out\rehearsal-<zon>` the same way. Alternatively, add `/zig-out-*/` to `.gitignore` and list
`.gitignore` as a touch point. Keep the `git check-ignore` preflight: it now guards something real.

**3. `tmux.pdb` never exists in a ReleaseFast build, so the x64 package step fails (R-M6-3 lines 212-213, Task 4 step 5 line 488, Task 2 line 420; R-M6-11 line 314).**
- `GhosttyTmuxShim.zig` builds the shim with `.strip = cfg.optimize != .debug`, so it ignores `-Dstrip=false`. Zig's
  `Compile.producesPdbFile` returns false for a stripped module, so no `tmux.pdb` is emitted or installed. Evidence:
  `zig-out-rf/bin` has `tmux.exe` and no `tmux.pdb`.
- Task 4 step 5 requires `ghostty.pdb` **and** `tmux.pdb` with `-Symbols` ("Missing → FAIL"). `release.ps1` passes
  `-Symbols` for x64 without `-NoPdbOk`, so step 5 of the release run fails on x64.
- The other direction is wrong too. R-M6-11 says "a `-gnu` build may emit no `.pdb`", but `producesPdbFile` has no ABI
  check: Windows, LLVM and not stripped are enough. `InstallArtifact` installs the PDB whenever that function says so.
  So the arm64 `-symbols.zip` should exist, and the `-NoPdbOk`/"no symbols (gnu)" branch is speculative. The asset counts
  disagree as well: Task 11 step 2 says 6 artifacts and checklist 8 says 7 assets, which assumes arm64 symbols exist,
  while R-M6-11 and checklist 1 make them optional.

Fix:
- Task 2 (already touching `GhosttyTmuxShim.zig`) sets `.strip = cfg.strip`, so `-Dstrip=false` gives `tmux.pdb` and the
  default stays stripped in release modes. Note that `cfg.strip` defaults to true for ReleaseFast.
- Otherwise, `package.ps1 -Symbols` requires only `ghostty.pdb` and adds `tmux.pdb` when it exists.
- R-M6-11: replace "may emit no `.pdb`" with "expected to emit a PDB (std.Build installs one for any non-stripped
  Windows LLVM build); `-NoPdbOk` is a fallback only". Make the counts conditional in one place, e.g. "5 or 6 artifacts
  + `SHA256SUMS.txt`".

**4. The PowerShell 5.1 scripts break in five concrete ways (Global Constraints lines 61/96, Task 4 line 482, Task 6 line 556, Task 7 line 582, Task 8 lines 357/622).**
- **`bash` is WSL on this machine.** `C:\Windows\System32\bash.exe` exists. From PowerShell, `bash <lock> -- <zig> …`
  (Task 8 step 2, and the `LOCK` abbreviation if typed into PowerShell) resolves through PATH to the WSL launcher, not to
  Git Bash. `test/windows/e2e.ps1:123` already resolves `"$env:ProgramFiles\Git\bin\bash.exe"` explicitly; `release.ps1`
  must reuse that lookup and fail the preflight with the paths it tried.
- **Native stderr with `$ErrorActionPreference = 'Stop'`.** In Windows PowerShell 5.1, redirecting a native command's
  stderr (`2>&1`, or capturing it to parse counts) turns each stderr line into an ErrorRecord. Under `Stop`, the first
  one aborts the script. `zig build` writes progress, warnings (e.g. the `tic not found` warning) and the test summary to
  stderr. Fix: run native steps through one helper that sets `$ErrorActionPreference = 'Continue'` locally, tees to
  `release.log`, and decides on `$LASTEXITCODE` only (or uses `Start-Process -Wait -RedirectStandardError`).
- **Non-ASCII literals.** PowerShell 5.1 reads a BOM-less `.ps1` as the ANSI code page. The em dash in the ProductName
  check (Task 4) and `Portable Ж` / `Inst Ж` (Tasks 6/7) would be mis-decoded, and the comparison or path would be
  wrong. The repo's convention is code points: `[char]0x0416` in `e2e/_selftest-clipboard.ps1:15`, `[char]0x240A` in
  `dialogs.ps1`. State it in Global Constraints: no non-ASCII literal in a `.ps1`; use `[char]0x2014` and `[char]0x0416`.
- **No counts to parse.** Zig 0.17's default build summary is `failures` ("Only print failed steps",
  `ScannedConfig.zig:348`), so a green `zig build test` prints no pass/skip counts. `tests.txt` and the notes'
  `{{TESTS}}` would be empty. Pass `--summary all` to the test steps and parse the per-run lines.
- **`-N <int>` cannot see `07` or `+5`.** PowerShell converts both to 7/5 before the script runs, so the canonical-N rule
  and its self-test rows (Task 8 lines 606-608) cannot fail. Declare `-N` as `[string]` and convert after the check.

**5. Ghostty running during an uninstall, or an upgrade where the user declines to close it, leaves a half-done install (Review Focus 2 lines 141-146, R-M6-4 lines 230-233, exit checklist 8 lines 784-788).**
- Review Focus 2 promises "no half-replaced install dir (Inno's retry/abort on a locked file)". With
  `CloseApplications=yes`, the user can still choose "Do not close the applications" on the Restart Manager page. Setup
  then hits the locked `ghostty.exe`/`tmux.exe` and offers Retry/**Ignore**/Abort per file. Ignore leaves an old exe
  next to a new `share`.
- Uninstall: the Restart Manager page is a Setup feature (verify in Task 5). The uninstaller runs `[UninstallRun]`
  first, which removes the verbs, then fails to delete the running exes. A per-user uninstaller cannot schedule
  delete-on-reboot. The result is a leftover `ghostty.exe` and an install dir with no Apps & features entry left to
  remove them. The exit checklist never tests uninstall while Ghostty runs.

Fix (all in `ghostty.iss`, Task 5):
- `[Code] InitializeUninstall`: while `FindWindowByClassName('<tray class_name from tray.zig>')` finds a window, show
  "Close Ghostty (including the tray icon) to continue" with Retry/Cancel. Cancel aborts the uninstall before
  `[UninstallRun]` runs. Fix the class name in one place, and have `package.ps1` check that it matches `tray.zig` as it
  does for the AUMID.
- `PrepareToInstall`: if the same window still exists after the Restart Manager step, return
  `'Ghostty is still running…'`, which stops Setup cleanly instead of offering Ignore.
- Exit checklist 8 Uninstall gains "with Ghostty running (window, and tray only): the prompt appears; after closing,
  nothing is left but user files".

**6. A real upgrade (version N → N+1) is never tested, and stale files survive an upgrade (exit checklist 8 line 784, R-M6-4 line 232, line 791, RELEASING step 7 line 640).**
- Checklist 8 upgrades "over the same version". That re-runs the same file list, so it cannot show:
  - files that the new version no longer ships (renamed or removed themes, shell-integration files);
  - the remembered `explorer` task on a real upgrade;
  - a different `AppVersion` in Apps & features.
- With `[Files] … recursesubdirs` and no `[InstallDelete]`, a theme removed upstream stays in `share\ghostty\themes`
  and keeps appearing in `+list-themes` until uninstall.
- The last line of checklist 8 builds yet another local ReleaseFast with `-win.0` just to see the update toast. That is
  one more heavy build for something the rehearsal already produced.

Fix:
- The owner installs the Task 9 rehearsal setup (`<zon>-win.0`, the real installer, owner-only) before Task 11. In Task
  11 they upgrade it to the RC setup (`-win.1`) while Ghostty runs. After publishing, the still-installed `-win.0` build
  with `auto-update = check` shows the toast for `-win.1`. Then the separate local RF build in line 791 can go.
- `ghostty.iss`: `[InstallDelete] Type: filesandordirs; Name: "{app}\share\ghostty\themes"` and the same for
  `{app}\share\ghostty\shell-integration`. Ghostty fully owns both dirs, and user files never go there. Never use
  `{app}\*`.

**7. Task 11 runs `release.ps1` after an upstream rebase but before the push, so the ancestry check refuses it (Task 11 steps 1-2 and 6, lines 687-695; R-M6-7 line 272).**
- `release-version.ps1` refuses unless HEAD is an ancestor of the local `origin/windows`. Step 1 rebases on upstream,
  which rewrites `windows`. Step 2 then runs `release.ps1 -N 1 -V1` on a HEAD that `origin/windows` does not contain.
  The plan puts "push the `windows` branch" in step 6.
- Without a rebase the same thing happens for any local commit made after the last push, e.g. 9.n fixes.

Fix: insert Task 11 step 1a (owner): "push `windows` (`--force-with-lease` after a rebase), then `git fetch origin
--tags`". Step 6 then pushes only the acceptance commit. RELEASING.md step 2 gets the same "push first" line.

**8. The `-Dstrip=false` ReleaseFast build is unmeasured, and its first run is the two-build rehearsal (lines 84, 100, 212-214, 327, 621; owner's global rule 3).**
- G1's `RF` abbreviation (line 100) has no `-Dstrip=false`, so G1 builds the stripped binary that M5 already measured.
  The first ReleaseFast build with full debug info and PDB linking therefore happens inside Task 9, twice in a row.
- The machine has "~4–5 GB free" (DECISIONS line 32). The 3 GB free-memory gate and the test-lock's 2 GB slot rule were
  never calibrated against this build (LLVM debug info for the whole Zig module plus an LLD PDB link). The owner's rule
  is to make sure RAM suffices first, or the machine hangs.
- The rationale on line 213 is partly stale: since 7f5ff2096 Windows builds keep unwind tables even when stripped. The
  only runtime effect of `-Dstrip=false` is frame pointers (`omitFramePointer() = strip`).

Fix:
- G1 builds x64 with `-Dstrip=false -j4` once, records the peak working set of `zig.exe`/`clang`/`lld` (and the size of
  `ghostty.pdb`), and sets `release.ps1`'s free-memory gate to that peak plus a margin before Task 8 fixes the number.
- If the peak does not fit, R-M6-3's fallback (strip, no symbols) applies before the rehearsal, not after.
- Fix the line-213 text.

**9. `--only-this-exe` is never tested in the direction that matters: deleting this exe's own verbs (Task 3 lines 459-466, Task 7 lines 585-590, R-M6-4 line 234).**
- The dangerous failure for Review Focus 1 is that the uninstaller keeps everything. For example, the CLI compares a
  path in another form (a `\\?\` prefix, an 8.3 name, a different `{app}` spelling), so verbs pointing to a deleted exe
  stay in every folder menu.
- Task 3's pure test covers the match, but the CLI hive test (line 461) seeds only verbs for `C:\Other\ghostty.exe`, so
  a CLI that passes the wrong path still passes. Task 7's test installer runs `[UninstallRun]` with `--dry-run`, so the
  installer never runs the real flag either. Only the owner's manual check would notice.
- The CLI honours `GHOSTTY_WIN32_TEST_HIVE` only together with `GHOSTTY_WIN32_TEST_IPC=1`
  (`explorer_integration.zig:52-55`, `117-125`). Task 7's env (line 582) sets only the hive. That is harmless today only
  because of `--dry-run`. Remove `--dry-run` without adding `TEST_IPC=1`, and the uninstall writes the real `HKCU`.

Fix:
- Task 3's hive test also seeds three verbs whose command names the running test exe (`std.process.executablePath`,
  the same call the CLI uses). With the flag they are deleted and the foreign ones kept.
- Task 7: the test variant's `[UninstallRun]` drops `--dry-run`. The scenario sets `GHOSTTY_WIN32_TEST_IPC=1` and
  `GHOSTTY_WIN32_TEST_HIVE=<sandbox>\hive.dat`. Before the uninstall it seeds the hive (through the CLI's
  `+install-explorer-integration` run from the installed exe, same env) plus one foreign verb. After the uninstall it
  asserts the installed exe's verbs are gone, the foreign verb is kept, and the hive's AUMID keys are gone. The
  toast-icon delete lands in the sandbox `LOCALAPPDATA`. The real `HKCU` is still never opened, and the snapshot assert
  stays.
- Keep `--dry-run` only as a belt-and-braces fallback if the hive cannot be opened; the scenario then SKIPs, it does
  not pass.

**10. SmartScreen is checked where it cannot appear, and Smart App Control is not mentioned (exit checklist 8 line 781, R-M6-9 lines 297-302, README line 494).**
- The owner's manual checks run "on the local artifacts before publishing". Files built locally have no
  Mark-of-the-Web, so SmartScreen never shows. "The SmartScreen warning is as documented" passes without testing
  anything.
- Smart App Control is on by default on clean Windows 11 22H2+ installs. It blocks unsigned apps without reputation
  outright, with no "More info → Run anyway". For those users neither the setup nor the zip runs, and the README's
  advice does not apply. That is the real cost of "no certificate" for a v1.0.

Fix:
- Move the SmartScreen line to "After publishing": download the setup and the zip in a browser, run them, and record
  the prompt (Unknown publisher → More info → Run anyway). Also record whether Smart App Control is on.
- README-windows.txt, the release notes and R-M6-9 state: "Smart App Control blocks this unsigned build; turning it off
  is a one-way switch in Windows Security, so prefer the zip on such machines only if you accept that" (or simply "not
  supported with Smart App Control on").

**11. The third-party coverage check cannot see the code the toolchain links (R-M6-10 lines 303-306, Task 13 lines 743-752).**
- The check reads `build.zig.zon` and `pkg/*/build.zig.zon` only. Both exes also contain code that no zon file names:
  - Zig's std and compiler_rt (MIT);
  - for `aarch64-windows-gnu` (R-M6-11): LLVM libc++/libc++abi/libunwind (the C++ deps HarfBuzz, simdutf, highway,
    glslang, SPIRV-Cross and Dear ImGui need a C++ runtime), the MinGW-w64 CRT, and winpthreads if Zig links it;
  - the transitive deps of remote Zig packages (e.g. `vaxis`, `z2d`, `zf`), whose own `build.zig.zon` lives in `zig-pkg`.
- The check would pass while the notices are incomplete for the ARM64 artifacts. Owner decision 1 asks for complete
  notices before v1.0.

Fix:
- `third-party-check.ps1` has a fixed "toolchain" table per arch: x64-msvc gets Zig std/compiler_rt; arm64-gnu adds
  libc++, libc++abi, libunwind, mingw-w64 (and winpthreads if present). Each needs a section in the notices.
- Task 13 step 2 confirms what the gnu link really pulls in, e.g. from the linker's `--verbose-link` output on one
  arm64 build.
- The check reads the `build.zig.zon` of every package under `zig-pkg` reachable from the root, not only `pkg/*`.

## MINOR

**12. The ARM64 test exe has no build path (R-M6-6 lines 256-259, Task 8 step 4 line 624).**
`-Demit-test-exe` installs the test exe only as part of the `test` step (`build.zig:417-420`). The same step also runs
it (`build.zig:427-428`). For an aarch64 target, Zig's Run step fails with "unable to spawn foreign binary" because
`skip_foreign_checks` is false (`compiler/Maker/Step/Run.zig:2957-2965`). The exe would be installed, but the step
fails, so `release.ps1` would see a failure. Fix: one line in `build.zig`,
`test_run.skip_foreign_checks = true;` (the step is then skipped on a foreign target). Add `build.zig` to the touch
points for that line only. Otherwise, state now that the ARM64 owner check is the smoke alone and drop `-Arm64TestExe`.

**13. `versioninfo.rc` uses names that resinator does not know without a header, and lacks `FILEFLAGSMASK` (R-M6-2 lines 190-201, Task 2 line 415).**
`VOS_NT_WINDOWS32`, `VFT_APP`, `VS_FF_*` and `VS_FFI_FILEFLAGSMASK` are `winver.h` macros. Today's `ghostty.rc`
defines `RT_MANIFEST` by hand and uses none of them. Either `#include <winver.h>` (resinator's auto-includes find the
MSVC or the bundled MinGW headers; the gnu target uses MinGW), or write `0x40004L`, `0x1L` and `0x3FL` with comments.
Without `FILEFLAGSMASK 0x3FL` the flags are undeclared, and readers that mask `dwFileFlags` report
`IsPreRelease`/`IsDebug` false, which would fail the Task 2 step 3 check.

**14. `fileVersion` and `winN` disagree on build metadata, and the "names the value" error is unreachable for most bad N (R-M6-1 line 188, Task 1 lines 386-401).**
- `1.3.2-dev-win.3+abc`: `winN` (string) gives null, so the update check treats it as a local build. `fileVersion`
  (on the `SemanticVersion`, `pre = "dev-win.3"`) gives FILEVERSION `.3`. Reject build metadata on a `-win.` version in
  `Config.zig`.
- `07`, `+5` and an empty N already fail `std.SemanticVersion.parse` (leading-zero rule, `SemanticVersion.zig:119-121`,
  `145`). That error is a bare `InvalidVersion` that does not name the value. Do the `-win.` check on the raw
  `-Dversion-string` text before `parse` if the message matters.
- Apply the `-win.` rule only to `-Dversion-string`, never to git-derived dev versions, whose branch part is free text.
- The `fileVersion` test inputs must be constructed `SemanticVersion` values, because `parse` would reject them first.

**15. `N = 0` passes as a real release (R-M6-7 lines 266-274, Task 8 lines 606-612, 650).**
With no `win-*` tag yet, "N greater than every existing N" holds for 0, which contradicts "N starts at 1". Refuse
`N = 0` without `-Rehearsal`; add the self-test row. Line 650's `-N 0 -SkipTests -DryRun → refused` is then refused
twice over; use `-N 1` there so that the test checks the `-SkipTests` rule only.

**16. RELEASING step 8 defeats the "N is never reused" rule (line 641, R-M6-7 line 266).**
"Delete the release and the tag; N is burned". `release-version.ps1` finds the highest N from local tags, so a
deleted tag frees its N again. Keep the tag and delete only the GitHub release. The update check reads releases, not
tags, so a tag without a release is invisible to users.

**17. The printed publish commands do not run in any shell (R-M6-7 lines 276-284).**
They mix bash's `\` line continuation with Windows backslash paths (`<OutDir>\release-notes.md`). In Git Bash the
backslashes escape the next character. In PowerShell `\` is not a continuation, and `--notes-file` with a backslash path
works only on one line. Print one line per command, in PowerShell syntax, with quoted absolute paths (or forward
slashes), and say which shell.

**18. Launching Ghostty from Inno pins `{app}` (R-M6-4 line 233, Task 5 line 532).**
The shell opens in home (see "What holds up"), but the Ghostty process's own CWD defaults to the Filename's directory,
i.e. `{app}`. Add `WorkingDir: {%USERPROFILE}` to the `[Run]` entry, as for the shortcut.

**19. PowerShell 5.1's `ZipFile.CreateFromDirectory` may write `\` entry separators (Task 4 step 4 line 487).**
`powershell.exe` targets an old .NET Framework profile, so `Switch.System.IO.Compression.ZipFile.UseBackslash`
defaults to true. That is the known cause of backslash zips from PS 5.1. Explorer copes; other tools and the Task 4
"one top folder" check (if it splits on `/`) do not. Call
`[AppContext]::SetSwitch('Switch.System.IO.Compression.ZipFile.UseBackslash', $false)` before the first use, and check
the entry names in the Task 4 verify.

**20. Task 4 step 1's failing check cannot fail on this machine (line 503).**
The current `zig-out/share/terminfo` already has `78\` and `67\`: M5's tic lookup finds Git's `tic.exe`. Use a
synthetic prefix (a copy of `zig-out` without `share\terminfo\78`) for the negative case.

**21. G1 runs `package-portable` without its input, so it SKIPs (line 327, Task 6 line 555).**
G1 lists `E2E -Only explorer-cli,package-portable,dpi-sim` but never sets `GHOSTTY_E2E_PACKAGE`, so the scenario SKIPs
and counts as green. Set it to the zip from the G1 `package.ps1` run, and treat a SKIP of a scenario whose input the
lead provided as a FAIL.

**22. The test installer can still land in the real install dir, and its `[Code]` must be gated too (R-M6-4 line 234, Task 5 lines 529-534, Task 7 line 576).**
- `/DGhosttyTest` keeps `DefaultDirName={autopf}\Ghostty`, so a run without `/DIR` (by hand, or by a scenario bug)
  installs into the real `%LOCALAPPDATA%\Programs\Ghostty`. Give the test variant its own default, e.g.
  `{%TEMP}\GhosttyTestInstall`, and `DisableDirPage=yes`.
- `CurStepChanged` calls `WizardIsTaskSelected('explorer')`, which fails at run time when `[Tasks]` is compiled out. Put
  that `[Code]` under `#ifndef GhosttyTest`.
- The guard "file name ends with `-setup-test.exe`" is weak. Also check the setup's VersionInfo (e.g.
  `VersionInfoDescription=Ghostty test installer`, set only in the test variant).

**23. README tells portable users to run `--all`, which also deletes the installed copy's verbs (Task 4 line 498, exit checklist 8 line 789).**
Without `--only-this-exe`, uninstall takes any `ghostty.exe` verb. The plan protects the portable copy from the
installer, but not the installer from the portable copy. README and checklist: `+uninstall-explorer-integration --all
--only-this-exe`.

**24. The ARM64 ABI is recorded inconsistently (lines 56, 243, 307-317, 678).**
- Global Constraints says "Target ABI MSVC", and R-M6-6 lists "VS Build Tools with the x64 **and ARM64** MSVC libraries"
  as release requirements. Both contradict R-M6-11 and owner decision 4.
- R-M6-11 is labelled "lead; owner may overturn", but the owner already chose `aarch64-windows-gnu`. Label it an owner
  decision.
- Task 10's DECISIONS amendment adds only the local-release line. It must also amend R3 for the ARM64 artifacts.
  DECISIONS line 3 says any change needs the owner's sign-off, and this one already has it.

**25. Over-built for a one-person project.**
- Task 12 (workflow, `install-zig.ps1` with a pinned hash, `choco`, a real-installer CI smoke, the `-Ci` mode in
  `release.ps1`): nothing depends on it. Move it to a backlog line in the CHANGELOG gaps instead of carrying a plan task
  and its `release.ps1` mode.
- R-M6-8: a signing hook (`-SignCommand` through three scripts, ISCC `/DSign`, `SignedUninstaller`, re-signing with
  `-FromZip`) with no certificate in sight. Keep `-FromZip`, which Task 9 needs for the test setup, and document signing
  as a future one-liner.
- `-Arm64Abi msvc` with a `vswhere` probe; `-Zig`, `-Lock`, `-KeepPrefix`. Each is a branch in the opus-reviewed release
  script.
- Budget rows "against the M5 acceptance rows re-measured the same day" (line 123) mean measuring the M5 binary again.
  Compare against the recorded M5 rows.

**26. Task 1 creates a real tag in the shared repository (line 406).**
Worktrees share refs, so `git tag win-0.0.0-0` is visible to every checkout and to `release-version.ps1` until it is
deleted. A crash between creating and deleting it leaves it behind, and `git push --tags` would publish it. Do the
check in a throwaway `git clone --local --no-checkout` + checkout, or rely on the `tagKind` unit test.

**27. The v1.0 gate in DECISIONS is only partly in the exit checklist (lines 774-777).**
- DECISIONS v1.0 requires "vttest-style checks". `test/windows/vt-smoke.ps1` is not an e2e scenario, so
  `E2E -Milestone all` does not run it. Add "`vt-smoke.ps1` against the RC exe" to line 3.
- "Upstream tests on Windows" is covered only by unit group 3's four filters. Say so explicitly in the acceptance
  record, so that the owner signs it knowingly.

**28. Missing release preconditions: repo visibility and agent tooling (RELEASING lines 633-641, lines 96, 617).**
- The update check (`api.github.com/repos/Denmurzik/ghostty/releases`, unauthenticated) and every download require the
  fork to be **public**. "Actions minutes exhausted" usually means a private repo, because standard runners are free for
  public ones. Add to RELEASING step 1: `gh repo view Denmurzik/ghostty --json visibility` → `PUBLIC`.
- `release.ps1` finds its test-lock under `%USERPROFILE%\.claude\mods\teamlead\…`, i.e. inside the owner's agent
  tooling. If it is missing, fall back to running the steps serially with the RAM gate rather than refusing. The release
  should not depend on the agent setup.

**29. Commit types (Task 13 line 761).**
"docs(windows): third-party notices…" also adds a PowerShell check and changes `package.ps1`; use `build(windows)`.

**30. A tag push also triggers upstream workflows (R-M6-6 line 264).**
`test.yml` (`push: {}`) and `nix.yml` (`on: [push, pull_request]`) run on tag pushes too, not only on branch pushes.
The plan already suggests disabling them in the fork's Actions settings. RELEASING step 1 should make that a one-time
setup step, so that every `win-*` tag does not queue failing jobs.

## Suggested order of fixes

Before W1, edit the plan only: 1 (privacy scan + neutral global cache), 2 (OutDir), 3 (tmux strip / symbols), 4 (PS 5.1
rules in Global Constraints), 7 (Task 11 push step), 8 (G1 strip=false measurement), 9 (positive `--only-this-exe`
tests; Task 7 with a real hive), 12/24 (ARM64 ABI and test-exe decisions).

During W2/W3: 5, 6, 13, 14, 15, 17-23 land in their tasks. 10, 11 and 27-30 land in Task 10 / RELEASING.md / Task 13.
