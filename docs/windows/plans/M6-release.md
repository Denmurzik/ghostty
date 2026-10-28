# M6 — Release (version resource, portable zip, Inno Setup installer, local release script, pre-release, v1.0 gate): Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the Windows port ships, for x64 and ARM64:
- `ghostty.exe` and `tmux.exe` with a Windows version resource (FILEVERSION/PRODUCTVERSION, ProductName, icon);
- a portable zip and a symbols zip;
- a per-user Inno Setup installer:
  - a Start-menu shortcut with the app's AUMID;
  - opt-in "Open Ghostty here";
  - terminfo;
  - `tmux.exe` and the bundled ConPTY next to `ghostty.exe`;
  - an uninstaller that removes only what it installed;
- a **local** release script (`dist/windows/release.ps1`) that, on the owner's machine:
  - builds x64 and ARM64 ReleaseFast with `-Dversion-string`;
  - runs the headless unit filters through the test-lock;
  - packages and privacy-scans the artifacts;
  - writes `SHA256SUMS.txt`;
  - **prints** (never runs) the `git tag`/`git push`/`gh release create … --prerelease --draft` commands for the owner;
- `THIRD_PARTY_NOTICES.txt` in the zip and the install dir (owner decision 1);
- the v1.0 acceptance checklist, signed by the owner.

No GitHub Actions workflow is part of M6. A `workflow_dispatch`-only workflow is a backlog line (R-M6-6).

Exit (SPEC §17 M6): the owner signs the acceptance checklist (§ M6 exit checklist).

**Revision history (plan-m6, 2026-10-28):**
- **r3:** the owner's GitHub Actions minutes are exhausted, so the release path is local (R-M6-6, R-M6-7). The owner's answers to the open questions are recorded (§ Owner decisions).
- **r3a:**
  - the ARM64 release ABI is `aarch64-windows-gnu` (R-M6-11);
  - the bundled ConPTY ships (R-M6-12).
- **r4:** applies `docs/windows/plans/M6-preflight-review.md` (1 CRITICAL, 10 IMPORTANT, 19 MINOR; § Pre-flight dispositions):
  - the release builds use a neutral Zig global cache, and every artifact is privacy-scanned (C1);
  - the outputs move under `zig-out\` (I2);
  - `tmux.pdb` (I3);
  - PowerShell 5.1 rules (I4);
  - running-app guards in Inno (I5);
  - a real `N → N+1` upgrade and `[InstallDelete]` (I6);
  - push before the release run (I7);
  - the `-Dstrip=false` build is measured in G1 (I8);
  - `--only-this-exe` is tested on its own verbs (I9);
  - SmartScreen and Smart App Control are documented and tested with Mark-of-the-Web (I10);
  - the notices cover the toolchain runtimes (I11);
  - the optional workflow task is retired to a backlog line (MINOR 25).

**Architecture:**
- **Build.** A std-only helper, `src/build/windows_version.zig`, owns the version rules:
  - `win-` tag handling;
  - `-win.<N>` parsing of `-Dversion-string`;
  - FILEVERSION;
  - the generated `.rc` header.

  `Config.zig`, `GhosttyExe.zig` and `GhosttyTmuxShim.zig` call it. Its tests run in the main test exe.
- **Packaging.** PowerShell scripts under `dist/windows/`:
  - `package.ps1` stages, verifies, privacy-scans, zips, calls ISCC and optionally signs one arch;
  - `release.ps1` orchestrates a whole release (preflight, tests, two builds, two packages, sums, notes, printed commands);
  - `release-version.ps1` is the pure tag/version validation;
  - `third-party-check.ps1` checks the notices' coverage.
- **Installer.** One Inno Setup script for both arches (`/DArch=`).
  - A `/DGhosttyTest` variant has no uninstall key, no shortcuts and no Restart Manager. It installs into a temp dir by default, so a sandboxed e2e can install and uninstall it on the owner's machine.
- **Publishing** is the owner's: the script prints the commands; it never pushes, tags or calls `gh`.

**Tech Stack:** Zig 0.17.0, Zig's resource compiler, Windows PowerShell 5.1, Inno Setup 6.4+ (`ISCC.exe`, installed per-user), Git for Windows (`tic.exe`; Git Bash by full path for the test-lock), `gh` CLI (run by the owner only). ABIs: `x86_64-windows-msvc`, and `aarch64-windows-gnu` per R-M6-11.

**Spec:** `docs/windows/SPEC.md` (with `docs/windows/DECISIONS.md` the authority):
- §1 (non-goals: code signing, MSIX), §2 (`dist/windows/` layout), §3 (release recipe flags), §13 (packaging; as amended by M5 Task 20), §14 (RAM), §16 R15/R16, §17 M6, §18.3 (AUMID toasts).
- DECISIONS:
  - "Release": zip + Inno "built by GitHub Actions on tag", amended by R-M6-6; no certificate, SmartScreen accepted.
  - R3 (MSVC), amended for the ARM64 artifacts by R-M6-11.
  - The v1.0 gate: feature checklist closed; upstream + win32 tests; vttest-style checks; RAM; a Claude Code tmux run; the owner's smoke of a pre-release.
- M5 hand-over:
  - R-M5-5: Explorer keys, `--all`, the installer shortcut's AUMID;
  - R-M5-9/9a: update check, `<zon>-win.<N>`, `win-<zon>-<N>`, pre-releases, compare `N`;
  - R-M5-7: compiled terminfo, `-Dtic`;
  - the bundled-ConPTY work (`windows-conpty`, `-Dconpty-dir`).

Other inputs:
- Owner decisions for M6 (2026-10-28, binding; summarised in the Goal, the Rulings and § Owner decisions).
- The owner's global rule: check free RAM before heavy runs, or run them in smaller parts.
- Memory rules: speed over ceremony.
- Pre-flight: `docs/windows/plans/M6-preflight-review.md` (dispositions at the end).

**Starts** when M5 is accepted (Task 20) and the M5 19.n batch touching `src/build/Config.zig` (`tic`) has landed.
- Tasks 3, 4 and 5 touch no M5-owned file in flight, and may start once M5 W8 has started.
- Tasks 4 and 8 also wait for the M5 bundled-ConPTY work (branch `sdd/task-m5-conpty`) to land (R-M6-12).
- Task numbers are identities, not order: the wave table is the execution order. Task 12 is retired (backlog), and its number is not reused.

## Global Constraints

Carried from M1–M5 (every task implicitly includes these):

- **Zig and target.**
  - Zig 0.17.0 at `C:\tools\zig-x86_64-windows-0.17.0\zig.exe` (full path). Shell for agents: Git Bash.
  - Target ABI: MSVC for x64; `aarch64-windows-gnu` for the ARM64 release artifacts (R-M6-11).
  - Minimum OS: Windows 11 22H2 (Windows 10 best effort).
- **Scope.** Core edits only in "M6 core touch points". A cause found outside them: the implementer stops with evidence, and the lead schedules an `n.1` task.
- **Commits:** no `Co-Authored-By` or similar trailers. Never `python -` (nor `python3 -` with a heredoc).
- **Worktree bootstrap:** `cmd //c mklink /J "<worktree>\zig-pkg" "C:\D\den4ik\Ghostty\zig-pkg"`. A worktree's first (cold) build runs with `run_in_background` under `timeout 1500` through the test-lock.
- **Privacy** (pre-flight C1).
  - No Windows user name in any committed file, report, release note, **or published artifact**. Paths are written as `%USERPROFILE%`, `%LOCALAPPDATA%`, `%APPDATA%`. The release notes carry counts, never local paths.
  - Release builds (G1, Tasks 9 and 11) run with `ZIG_GLOBAL_CACHE_DIR=<repo>\zig-out\zig-global`. It is git-ignored through `zig-out/`, and has no user name in its path, so the PDBs no longer record `%LOCALAPPDATA%\zig\…`. The first such build is cold: compiler_rt and the libc++/MinGW libs are rebuilt once.
  - `package.ps1` fails with `package: FAIL privacy <file> @<offset>` if any staged file, PDB, setup exe, notes or sums file contains the user name or `%USERPROFILE%` (rule in Task 4).
  - The PDBs still record repo-relative source paths under the checkout (`C:\D\den4ik\Ghostty\…`). That is not the Windows user name. Building from a neutral checkout path is the owner's option (§ Owner decisions, note).
- **PowerShell 5.1 rules** (pre-flight I4). Scripts target Windows PowerShell 5.1 (`powershell -NoProfile`), `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, and no modules beyond the inbox ones. Also:
  - **No bare `bash`.** On this machine `C:\Windows\System32\bash.exe` is WSL. Git Bash is resolved by full path, with the lookup of `test/windows/e2e.ps1:123` (`$env:ProgramFiles\Git\bin\bash.exe`, then `…\usr\bin\bash.exe`). If neither exists → fail, naming both paths.
  - **Native commands** run through one helper, `Invoke-Native` (in `dist/windows/lib/Native.psm1`, Task 4). It sets `$ErrorActionPreference = 'Continue'` locally, tees stdout and stderr to the log, and decides on `$LASTEXITCODE` only. A stderr line never aborts a script.
  - **No non-ASCII literal** in a `.ps1`: write `[char]0x2014` (em dash) and `[char]0x0416` (Ж), as `e2e/_selftest-clipboard.ps1` does.
  - **Numbers that must stay canonical** (`-N`) are declared `[string]` and converted after the check.
  - **Zips** use `[IO.Compression.ZipFile]` after `[AppContext]::SetSwitch('Switch.System.IO.Compression.ZipFile.UseBackslash', $false)`; entry names use `/`.
  - Each new script must parse:
    ```
    powershell -NoProfile -Command "[ScriptBlock]::Create((Get-Content -Raw <file>)) | Out-Null"
    ```

**Owner safety (M2–M5 rules, extended for M6).** None of these needs a per-run approval, because none touches owner state.

- **Harness.** e2e scenarios run only through `test/windows/e2e.ps1`:
  - shared desktop lock, a per-scenario `class`, the sandbox env (`New-E2eSandbox`: `XDG_CONFIG_HOME`, `APPDATA`, `LOCALAPPDATA`, `USERPROFILE` under the sandbox);
  - every Ghostty a scenario starts gets `--class=<scenario class>`, is registered with `Register-OwnGhostty` and stopped in `finally`;
  - evidence images only through the guarded capture helpers.
- **Registry.** No test, scenario, implementer run or `release.ps1` run writes the real `HKCU`/`HKLM`.
  - The Explorer CLI runs only with `--dry-run`, or with `GHOSTTY_WIN32_TEST_IPC=1` **and** `GHOSTTY_WIN32_TEST_HIVE=<file>`. The CLI honours the hive only together with test mode (`explorer_integration.zig`).
  - The **real** installer and uninstaller never run in a test, an implementer run or `release.ps1`; they run only in the owner's manual checks.
  - On the owner's machine only the `/DGhosttyTest` installer runs (R-M6-4). It has:
    - no uninstall key and no shortcuts;
    - no Restart Manager session (so none of RM's volatile `HKCU\Software\Microsoft\RestartManager` keys);
    - no Explorer task and no running-app `[Code]`;
    - a default dir under `%TEMP%`.

    Its uninstaller runs the real `--all --only-this-exe` against the scenario's app hive. The scenario snapshots the relevant `HKCU` keys read-only before and after, and asserts no change.
- **Files.** Packaging and `release.ps1` write only under `zig-out\` (default `-OutDir` `zig-out\release\<version>`, which `.gitignore`'s `zig-out/` covers; Task 8 keeps a `git check-ignore` preflight). Nothing writes `%LOCALAPPDATA%\Programs`, the Start menu, the desktop or `%USERPROFILE%\.config\ghostty` on the owner's machine, except the owner's manual checks.
- **Network.** No test reaches the internet (M5 ruling C3 holds). `release.ps1` makes no network call: it reads only local git refs and tells the owner to push and `git fetch --tags origin` first.
- **Outward-facing actions** (push, tag push, `gh release …`, publishing) are the owner's. `release.ps1` prints them; implementers and the lead never run them without the owner's explicit go for that action.
- **RAM.** Every heavy step (test compile, ReleaseFast build) runs through the test-lock (≥ 2 GB free per slot).
  - `release.ps1` also checks free physical memory before each heavy step. The gate is the peak measured in G1 for the `-Dstrip=false` build, plus 1 GB, and at least 3 GB.
  - It runs the unit filters in three smaller groups (owner's global rule).
  - Without the test-lock (the agent tooling is missing), it runs the same steps serially with the RAM gate; it does not refuse.

Speed rules (owner 2026-10-26/28; unchanged):

- Builds and tests use `-j6` through the test-lock (3 slots); the `-Dstrip=false` release builds use `-j4` (pre-flight I8). Bash timeout 600000. Prefer a focused `-Dtest-filter`; never the full suite locally.
- A ReleaseFast build with a different `-Dversion-string` rebuilds the whole exe: at most one such build per task (outside `release.ps1`), into its own `--prefix` under `zig-out\`.
- Implementers run unit tests, `LOCK ZIG build -j6`, script parse checks and the pure `-SelfTest`/`-DryRun` modes. The lead runs the e2e batches (G1, Task 11) and the release rehearsal (Task 9).
- Up to 3 writers in flight; a task starts as soon as its dependencies have landed and its files do not collide.
- Every task: unit tests or a self-test, plus at most one e2e scenario.
- **Review tier** (stated per task): `light` = one batched sonnet review per wave; `opus` = per-task review for what an uninstaller deletes, owner safety, privacy, or release integrity.

Command abbreviations (expand literally; shell state does not persist):
- `LOCK` = `bash "%USERPROFILE%/.claude/mods/teamlead/skills/teamlead/scripts/test-lock" --` (agents, from Git Bash only).
- `ZIG` = `"C:/tools/zig-x86_64-windows-0.17.0/zig.exe"`
- `PS` = `powershell -NoProfile -ExecutionPolicy Bypass -File`
- `E2E` = `PS test/windows/e2e.ps1` (lead only, after the build it tests).
- `RFS` = `ZIG_GLOBAL_CACHE_DIR="$PWD/zig-out/zig-global" LOCK ZIG build -j4 -Doptimize=ReleaseFast -Demit-themes=true -Demit-terminfo=true -Dstrip=false -Dtarget=x86_64-windows-msvc --prefix zig-out/rfs`. This is the local x64 release recipe; add `-Dversion-string=…` and `-Dconpty-dir=…` where a step says so.
- Test name prefixes: `windows version: ` (new, `src/build/windows_version.zig`), `windows explorer: `, `explorer cli: `, `win32 update: ` (existing).

### M6 core touch points (complete list)

| File | Change | Task |
|---|---|---|
| `src/build/windows_version.zig` | new, std only: tag kind, `-win.<N>` text rule, FILEVERSION, rc header | 1 |
| `src/build/Config.zig` | the git tag check ignores `win-` tags; the `-win.` rule on the raw `-Dversion-string` (R-M6-1) | 1 |
| `src/apprt/win32/update/release.zig` | `currentN` delegates to `windows_version.winN`; the test block references the new file | 1 |
| `src/build/GhosttyExe.zig` | generated version header + include path for `ghostty.rc` | 2 |
| `src/build/GhosttyTmuxShim.zig` | `tmux.rc` with the same header; `.strip = cfg.strip` (was `optimize != .debug`), so `-Dstrip=false` gives `tmux.pdb` (pre-flight I3) | 2 |
| `build.zig` | one line: `test_run.skip_foreign_checks = true` (foreign-arch test exe is installed, not run; pre-flight MINOR 12) | 2 |
| `dist/windows/ghostty.rc` | `#pragma code_page(65001)`; the commented VERSIONINFO block replaced by `#include "versioninfo.rc"` | 2 |
| `src/os/windows_explorer.zig` | `ownsKeyFor` (owner = this exe) | 3 |
| `src/cli/explorer_integration.zig` | `+uninstall-explorer-integration --only-this-exe` | 3 |

Not touch points:
- `src/apprt/win32/**` (other than `release.zig`), `src/termio/**`, `src/config/Config.zig`.
- `build.zig.zon`: the zon version stays upstream's (R-M5-9a).
- `.gitignore`: all outputs live under `zig-out/`.
- The upstream workflows in `.github/workflows/` (R-M6-6).

### RAM and latency budget

Same binary as M5, except the version resource and `-Dstrip=false` (frame pointers and debug info). Unwind tables are kept on Windows builds anyway since `7f5ff2096`.

Measured on the release candidate's x64 exe from the `release.ps1` zip, with `test/windows/measure-ram.ps1` and `input-latency`, against the **recorded** M5 acceptance rows (pre-flight MINOR 25).

| Item | Budget | Measured by |
|---|---|---|
| G1: the `-Dstrip=false` x64 build: peak working set of `zig.exe` + `clang`/`lld` children, and the size of `ghostty.pdb` | fits the machine; sets `release.ps1`'s RAM gate (peak + 1 GB, ≥ 3 GB) | G1 |
| RC `ghostty.exe`, default config, 1 window 1 surface, 30 s after start | ≤ M5 acceptance row + 1 MB | Task 11 |
| RC `OpenConsole.exe` (bundled ConPTY) per surface | reported next to the inbox `conhost.exe` value (not budgeted) | Task 11 |
| RC `tmux.exe` peak private (`display-message`) | ≤ 5 MB (SPEC §14) | Task 11 |
| Key echo, Ghostty-owned p95 | within +0.5 ms of M5 | Task 11 |
| Startup to first frame | within +10 ms of M5 | Task 11 |
| `release.ps1` full run | no step below the RAM gate; the wall time and the lowest free memory recorded | Task 9 |

Over budget: DONE_WITH_CONCERNS with numbers. If the `-Dstrip=false` build does not fit in G1, R-M6-3's fallback (strip, no symbols) is taken **before** the rehearsal.

## Review Focus

1. **The uninstaller removes exactly what the installer put there.**
   - Removed:
     - the installed files; the Start-menu (and optional desktop) shortcut; the uninstall entry;
     - the Explorer verbs that name **this** `ghostty.exe`;
     - the AUMID registration and the toast icon (`--all`).
   - Kept:
     - `%USERPROFILE%\.config\ghostty\**`;
     - `%LOCALAPPDATA%\ghostty\**` except the toast icon (logs, crash dumps, `update.json`);
     - files the user added under the install dir (and so the dir itself);
     - the verbs of another (portable) `ghostty.exe`.
   - Tests:
     - Task 3 `windows explorer: only-this-exe …`, `explorer cli: --only-this-exe deletes its own verbs and keeps a foreign one`;
     - Task 7 `installer-test.ps1`, a real `--all --only-this-exe` against an app hive;
     - owner checklist (the real installer).
2. **Install, upgrade or uninstall while Ghostty runs.** Cases: a window with shells; tray only; a Claude Code team using `tmux.exe` from the install dir.
   - Expected:
     - the Restart Manager page lists Ghostty, and "close automatically" ends it through `WM_QUERYENDSESSION`/`WM_ENDSESSION`;
     - if the user declines, `PrepareToInstall` stops Setup cleanly while the `GhosttyTray` window exists, so Setup never offers Ignore on a locked exe;
     - uninstall asks to close Ghostty before `[UninstallRun]` runs (R-M6-4);
     - an upgrade keeps the Explorer verbs and the remembered tasks, and removes themes and shell-integration files the new version no longer ships.
   - Known limit: a second Ghostty process without a pipe (`windows-single-instance = false`) has no tray window; only Restart Manager sees it.
   - Tests: owner checklist (the rehearsal `-win.0` → RC `-win.1` upgrade and an uninstall while running).
3. **One version everywhere.** Tag `win-<zon>-<N>` ↔ `build.zig.zon` version ↔ `-Dversion-string=<zon>-win.<N>` ↔ `+version` ↔ VersionInfo (FileVersion `major.minor.patch.N`) ↔ the update check's `N` ↔ the printed `git tag` (pinned to the built commit's SHA).
   - A malformed `N` never produces artifacts.
   - `N` only grows and is never reused: a bad release keeps its tag, and only the GitHub release is deleted.
   - `N = 0` exists only in a rehearsal.
   - A local build at a tagged commit neither panics nor counts as a release.
   - Tests: Task 1 `windows version: …`; Task 8 `release-version.ps1 -SelfTest`, `release.ps1 -DryRun`; Task 4 package verification; Task 9 rehearsal.
4. **Privacy of published artifacts** (pre-flight C1).
   - No published file carries the Windows user name or `%USERPROFILE%`: exe, PDB, DLL, setup, notes, sums.
   - The neutral global cache is in effect for every release build.
   - Tests: the Task 4 privacy check and its self-test; G1 runs it on a real `-Dstrip=false` PDB; Task 9.
5. **The release script on a low-RAM machine.**
   - Heavy steps run one at a time through the test-lock (or serially without it); the unit filters run in three groups.
   - A failed step stops the run with the step name and leaves no half-written `SHA256SUMS.txt`.
   - Refusals:
     - re-running with the same `N` refuses an existing output dir unless `-Force`;
     - a dirty tree, or a commit missing from the local `origin/windows`, refuses (except `-Rehearsal`).
   - Tests: Task 8 `-DryRun` and `-SelfTest`; Task 9 rehearsal (wall time and peak recorded).
6. **The portable zip from odd places.** Paths with spaces, Cyrillic, over 260 characters, a read-only folder; a zip whose `share` folder was moved; a zip downloaded by a browser (Mark-of-the-Web).
   - Expected:
     - resources found (`share\terminfo\ghostty.terminfo` sentinel);
     - `TERM` falls back to `xterm-256color` when the compiled entry is missing (R-M5-7);
     - `tmux.exe` first on `PATH` inside sessions;
     - the bundled `OpenConsole.exe` taken from the same folder;
     - nothing written next to the exe;
     - the pwsh integration unaffected by MOTW (it compiles the script rather than dot-sourcing it).
   - Tests: Task 6 `package-portable.ps1` (space + Cyrillic dir, MOTW on the zip); owner checklist (USB/read-only).
7. **Release binaries run on every target machine.**
   - Always an explicit `-Dtarget` (`x86_64-windows-msvc`; `aarch64-windows-gnu` by default, R-M6-11): CPU baseline, never the build machine's native features.
   - ARM64 with the MinGW ABI: does the gnu build behave like the msvc code paths (COM vtables, `callconv(.winapi)`, the `@alignCast` sites fixed in M3, the dump writer)?
   - The ARM64 unit tests cannot run on this machine; they are an owner check (R-M6-6).
   - Tests: Task 9 (both arches build and package; `+version` of x64 only); the owner's ARM64 test exe and smoke (non-blocking).
8. **Smart App Control and SmartScreen** (pre-flight I10).
   - An unsigned build is blocked outright on machines with Smart App Control on, which is the default on clean Windows 11 22H2+ installs.
   - SmartScreen's "Unknown publisher → More info → Run anyway" appears only for files with Mark-of-the-Web.
   - The docs say so plainly (R-M6-9), and the owner checks run with MOTW.

## Rulings (plan-m6, 2026-10-28; lead/owner may overturn; recorded in SPEC §18 by Task 10)

The owner's M6 decisions (binding, not re-asked):
- deliverables for x64 and ARM64 (zip, Inno installer, version resource in both exes);
- the version scheme of R-M5-9a;
- releases as GitHub pre-releases; no secret beyond `GITHUB_TOKEN`;
- signing is manual, and the plan provides the hook;
- per-user installer with the AUMID shortcut, opt-in Explorer integration, terminfo, `tmux.exe`; uninstall reverts with `--all` and never touches the config;
- the v1.0 checklist signed by the owner;
- the release path is local, and a workflow, if any, is `workflow_dispatch`-only and not required;
- the bundled ConPTY ships (R-M6-12);
- the answers in § Owner decisions.

- **R-M6-1 Versions in the build.**
  - **Tags.**
    - Today a commit whose exact tag is not `tip` and not `v<zon>` panics the build (`tagged releases must be in vX.Y.Z format`) unless `-Dversion-string` is given.
    - New rule: a tag starting with `win-` is treated like `tip`. The build falls through to the dev version `<zon-major.minor.patch>-<branch>+<hash>`.
    - The release version comes **only** from `-Dversion-string=<zon>-win.<N>`, which `release.ps1` passes after validating `N` (R-M6-7).
    - Accepting the tag (deriving the version from it) was rejected: two sources of truth, and a local build at a release commit would silently turn on the update check.
    - Upstream `vX.Y.Z` behaviour is unchanged.
  - **The `-win.` rule** (pre-flight MINOR 14). It applies to the **raw `-Dversion-string` text**, before `std.SemanticVersion.parse`, and never to git-derived dev versions (their branch part is free text). If the text contains `-win.`:
    - it must end in `-win.<N>`, with `N` canonical (`0` or `[1-9][0-9]*`) and `N ≤ 65535` (the FILEVERSION field limit);
    - it must carry no `+build` metadata.

    Anything else is a build error that names the value. So `winN` (text) and `fileVersion` (parsed) can never disagree.
  - Cost if wrong: one `switch` arm and one text check.
- **R-M6-2 Version resource** (both exes).
  - One VERSIONINFO block lives in `dist/windows/versioninfo.rc`; the per-exe values come from a header the build generates.
  - `FILEVERSION`/`PRODUCTVERSION` = `major,minor,patch,N` (`N = 0` without `-win.<N>`).
  - `FILEFLAGSMASK 0x3FL` (`VS_FFI_FILEFLAGSMASK`). `FILEFLAGS` = `0x2L` (`VS_FF_PRERELEASE`) when the semver has a pre-release part, `| 0x1L` (`VS_FF_DEBUG`) in Debug. `FILEOS 0x40004L` (`VOS_NT_WINDOWS32`), `FILETYPE 0x1L` (`VFT_APP`).
  - These are numeric literals with the macro name in a comment, so no `winver.h` is needed with either ABI's headers (pre-flight MINOR 13).
  - Strings (`040904b0`):
    - `ProductName` = `Ghostty — Unofficial Windows port` (SPEC §13; UTF-8 source with `#pragma code_page(65001)`);
    - `ProductVersion` = `FileVersion` = the full version string;
    - `FileDescription` = `Ghostty` / `Ghostty tmux shim` (Task Manager shows this);
    - `OriginalFilename`, `InternalName` = `ghostty.exe` / `tmux.exe`;
    - `LegalCopyright` = `Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors` (`LICENSE`);
    - no `CompanyName`.
  - Icon: `ghostty.ico` in both (`tmux.rc` is new). It adds no imports, so `tmux.exe` still imports only kernel32/ntdll.
- **R-M6-3 Artifacts and layout.**
  - **Names:**
    - `ghostty-<version>-windows-<arch>.zip`;
    - `ghostty-<version>-windows-<arch>-setup.exe`;
    - `ghostty-<version>-windows-<arch>-symbols.zip` (`ghostty.pdb`, `tmux.pdb`);
    - one `SHA256SUMS.txt` for all assets.

    `<arch>` is `x64` or `arm64`; `<version>` is the `-Dversion-string`. A release has **6 artifacts + `SHA256SUMS.txt`**. That drops to 5 only if the arm64 build gives no PDB, in which case `-NoPdbOk` is printed in the notes (R-M6-11).
  - **Zip content.** One top folder `ghostty-<version>-windows-<arch>/`, so that extraction never spills files. Inside:
    - `ghostty.exe`, `tmux.exe`, `conpty.dll`, `OpenConsole.exe` (R-M6-12);
    - `LICENSE`, `THIRD_PARTY_NOTICES.txt` (R-M6-10), `README-windows.txt`;
    - `share/` with the existing subfolders among `ghostty`, `terminfo`, `bash-completion`, `fish`, `zsh`, `vim`, `nvim`, `bat`, `man` (an allowlist; anything else in the prefix, e.g. Linux desktop files, is left out);
    - no `.pdb`.
  - **Required files** (else packaging fails):
    - `share/ghostty/themes` (non-empty) and `share/ghostty/shell-integration`;
    - `share/terminfo/ghostty.terminfo` (the resources sentinel of `resourcesdir.zig`);
    - `share/terminfo/78/xterm-ghostty` (compiled, R-M5-7). Only a non-release local run may waive it with `-AllowNoTic`; `release.ps1` never does.
  - **Release build flags:** `-Doptimize=ReleaseFast -Demit-themes=true -Demit-terminfo=true -Dstrip=false -Dtic=<Git's tic.exe> -Dversion-string=<v> -Dconpty-dir=<the arch's dir>`, with `-Dtarget=x86_64-windows-msvc` or `-Dtarget=aarch64-windows-gnu` (`msvc` optional, R-M6-11), `-j4`, and `ZIG_GLOBAL_CACHE_DIR` set (privacy).
  - **Why `-Dstrip=false`:** it yields the PDBs for the M5 crash dumps, shipped only in `-symbols.zip`. Its runtime effect is frame pointers; unwind tables are kept anyway since `7f5ff2096`. Its build cost is measured in G1 (pre-flight I8).
  - Cost if wrong (G1 or the Task 11 RAM/latency rows): the default strip, and no symbols.
- **R-M6-4 Installer** (`dist/windows/installer/ghostty.iss`).
  - **Privileges and arch.**
    - Per-user only: `PrivilegesRequired=lowest`, no override dialog. Per-machine is a v1.0 gap (owner decision 3).
    - `DefaultDirName={autopf}\Ghostty` (`%LOCALAPPDATA%\Programs\Ghostty`); `DisableProgramGroupPage=yes`.
    - `AppId={{37134A5A-16BD-4127-9CC0-134E0CF32BA5}`, fixed forever.
    - x64: `ArchitecturesAllowed=x64compatible`, `ArchitecturesInstallIn64BitMode=x64compatible`. arm64: both `arm64`.
    - `MinVersion=10.0.17763` (the ConPTY floor; Windows 10 is best effort per DECISIONS).
  - **Files.**
    - The zip's content: same stage, same allowlist.
    - `[InstallDelete] Type: filesandordirs` for `{app}\share\ghostty\themes` and `{app}\share\ghostty\shell-integration`. Ghostty owns both dirs fully, so an upgrade drops removed files (pre-flight I6). Never `{app}\*`.
    - `UninstallDisplayIcon={app}\ghostty.exe`; `SetupIconFile=..\ghostty.ico`; `WizardStyle=modern`; English only; no license page (MIT; the file is installed).
  - **Shortcuts.**
    - `[Icons]` `{autoprograms}\Ghostty` → `{app}\ghostty.exe`, `WorkingDir: {%USERPROFILE}`, `AppUserModelID: "com.mitchellh.ghostty.windows-unofficial"`. That is the release `windows_explorer.aumid`; `package.ps1` checks that they match.
    - The optional desktop shortcut (task `desktopicon`, unchecked) is the same.
  - **Explorer task `explorer`** (unchecked, label `Add "Open Ghostty here" to the Explorer folder menu`).
    - `[Code]` `CurStepChanged(ssPostInstall)` runs `{app}\ghostty.exe +install-explorer-integration` hidden and waits.
    - A non-zero exit shows a suppressible warning and is logged; the install still succeeds.
    - Unticking it on an upgrade does not remove existing verbs; the uninstaller does.
  - **Running Ghostty** (pre-flight I5). The tray window class `GhosttyTray` is defined once as `#define TrayClass`; `package.ps1` checks it against `src/apprt/win32/tray.zig` as it does for the AUMID.
    - `CloseApplications=yes`, `RestartApplications=no`.
    - `PrepareToInstall`: if `FindWindowByClassName('{#TrayClass}')` still finds a window after the Restart Manager step, return `Ghostty is still running. Close it (including the tray icon) and run Setup again.` Setup stops cleanly; it never reaches a per-file Ignore.
    - `InitializeUninstall`: while that window exists, show `Close Ghostty (including the tray icon) to continue.` with Retry/Cancel. Cancel aborts before `[UninstallRun]` runs.
  - **Uninstall.**
    - `[UninstallRun]` always runs `{app}\ghostty.exe +uninstall-explorer-integration --all --only-this-exe` (hidden, waits, `RunOnceId: "ExplorerRevert"`), whether or not the task was ticked. `--all` also removes the AUMID key and toast icon the app creates at runtime (SPEC §13). `--only-this-exe` (R-M6-5) keeps a portable copy's verbs.
    - No `[UninstallDelete]`: Inno removes exactly the files it logged, and user-added files keep the dir.
  - **After install:** no PATH change (SPEC §13). The postinstall "Launch Ghostty" entry has `WorkingDir: {%USERPROFILE}` and `postinstall nowait skipifsilent` (pre-flight MINOR 18).
  - **`/DGhosttyTest`** (Task 7 only; pre-flight MINOR 22).
    - `AppId={{B6635077-20E7-4DDF-A062-7D9F8711ADF2}`, `DefaultDirName={%TEMP}\GhosttyTestInstall`, `DisableDirPage=yes`, `VersionInfoDescription=Ghostty test installer`.
    - `CreateUninstallRegKey=no`, `CloseApplications=no`; no `[Icons]`, no `[Tasks]`.
    - No `[Code]` for Explorer or running apps: `#ifndef GhosttyTest` around both. The owner's own running Ghostty must not block the test.
    - The same `[UninstallRun]` as the release, with no `--dry-run`. The scenario's env (`GHOSTTY_WIN32_TEST_IPC=1` + `GHOSTTY_WIN32_TEST_HIVE`) redirects it to an app hive.
    - The output name ends `-setup-test.exe`.
- **R-M6-5 `+uninstall-explorer-integration --only-this-exe`.**
  - With the flag, a verb key counts as ours only if its `command\(default)` names this very exe.
  - The comparison is on full paths, after `GetFullPathNameW` and `GetLongPathNameW` on both sides (no `\\?\` prefix, no 8.3 form), with `CompareStringOrdinal(…, TRUE)` on UTF-16.
  - The own path comes from `std.process.executablePath`.
  - Without the flag, the R-M5-5 rule (any `ghostty.exe`) is unchanged.
  - `--all`'s AUMID and toast-icon removal is not affected.
  - `--dry-run` with the flag prints `delete <key> if its command names <exe>`.
- **R-M6-6 Local release path; no CI in M6** (owner update 2026-10-28; amends DECISIONS "built by GitHub Actions on tag" and SPEC §13's CI line).
  - **A release needs only the owner's machine:**
    - Zig 0.17.0;
    - VS Build Tools with the **x64** MSVC libraries (present; ARM64 needs none, R-M6-11);
    - Git for Windows (`tic.exe`, Git Bash);
    - Inno Setup 6.4+, already installed per-user (owner decision 2). Found at `%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe`, else `%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe` or `%ProgramFiles%\Inno Setup 6\ISCC.exe`; `$env:ISCC` overrides. None → the release stops with `ISCC.exe not found (looked in: <the three paths>); install Inno Setup 6 or set ISCC`;
    - the ConPTY NuGet package (R-M6-12);
    - `gh` logged in (used only by the owner, by hand).
  - **Unit tests in `release.ps1`:** three groups, each one test-exe compile through the test-lock, then `test-tmux-shim`, all with `--summary all` so that the counts can be parsed (pre-flight I4). These are the M1–M5 exit filters, all headless:
    1. `-Dtest-filter="win32 "`;
    2. `-Dtest-filter="windows " -Dtest-filter="tmux shim " -Dtest-filter="Exec: w" -Dtest-filter="d3d11 "`;
    3. `-Dtest-filter="terminal" -Dtest-filter="config" -Dtest-filter="input" -Dtest-filter="font"` (the upstream tests on Windows that the v1.0 gate names; the acceptance record says so explicitly).

    The groups are defined once, in `release.ps1`. Any failure stops the release.
  - **ARM64** (owner decision 4: ARM64 checks never block a release).
    - Cross-built locally (R-M6-11).
    - Its unit tests are an **owner check**: with `-Arm64TestExe`, `release.ps1` builds one ARM64 test exe and zips it as `ghostty-<v>-windows-arm64-tests.zip` (local only, never published).
      - The build is `zig build test -Demit-test-exe -Dtarget=aarch64-windows-<abi>` with the group 1+2 filters.
      - It installs without running, thanks to `skip_foreign_checks` (Task 2).
      - The owner runs it on an ARM64 device: exit 0 = PASS, and a failure is recorded, not blocking.
  - **No workflow in M6** (pre-flight MINOR 25).
    - A `workflow_dispatch`-only `windows-ci.yml` (with ARM64 unit tests on `windows-11-arm`) is a backlog line in the CHANGELOG.
    - Ruling for the owner to overturn: standard GitHub-hosted runners are normally free for **public** repositories. "Minutes exhausted" usually means the repo is private, and the update check needs it public (RELEASING step 1). If the fork is public and runners are free, the backlog item can come back after v1.0. The release path stays local either way.
  - **Upstream workflows** are not edited (clean merges). Their jobs ask for `namespace-profile-*` runners the fork does not have, and `test.yml`/`nix.yml` also run on tag pushes. Disabling them in the fork's Actions settings is a one-time RELEASING step (pre-flight MINOR 30).
- **R-M6-7 Release.**
  - **Tag.** `win-<zon>-<N>`, annotated, created and pushed by the owner from the command `release.ps1` prints, and pinned to the built commit's SHA.
    - `N` starts at **1**, is fork-wide and is never reused.
    - A bad release keeps its tag; only the GitHub release is deleted. The update check reads releases, not tags (pre-flight MINOR 16).
  - **Validation** (`dist/windows/release-version.ps1`, R-M5-9a rules; `-N` is a `[string]`). It refuses when:
    - `N` is not canonical (`0|[1-9][0-9]*`), or `N > 65535`;
    - `N = 0` without `-Rehearsal`, or `N ≠ 0` with it (pre-flight MINOR 15);
    - `<zon>` is not `build.zig.zon`'s `.version`;
    - `N` is not greater than every local `win-*` tag's `N` (the script tells the owner to `git fetch --tags origin` first);
    - the tree is dirty;
    - HEAD is not an ancestor of (or equal to) the local `origin/windows`: the owner pushes first (pre-flight I7).
  - **Rehearsal.** `-Rehearsal` builds with `N = 0` and skips the last three checks. It marks every printed command `# REHEARSAL - do not run` and writes to `zig-out\release\rehearsal-<zon>\`.
  - **Printed commands** (pre-flight MINOR 17). PowerShell syntax, one line each, absolute quoted paths, to stdout and `<OutDir>\publish.txt`, headed `# Run in PowerShell from the repo root`:
    ```
    git tag -a 'win-<zon>-<N>' '<sha>' -m 'Ghostty <zon>-win.<N>'
    git push origin 'win-<zon>-<N>'
    gh release create 'win-<zon>-<N>' --repo Denmurzik/ghostty --prerelease --draft --verify-tag --title 'Ghostty <zon>-win.<N> (unofficial Windows port)' --notes-file '<abs>\release-notes.md' '<abs>\<artifact 1>' … '<abs>\SHA256SUMS.txt'
    gh release edit 'win-<zon>-<N>' --repo Denmurzik/ghostty --draft=false
    ```
    The last line is preceded by `# after checking the draft page`.
  - **Order.** The owner smokes the **local** artifacts first (exit checklist 8), runs the commands, checks the draft page, and publishes. The update check ignores drafts and reads pre-releases (R-M5-9), so users see the release only after the last command.
  - **Notes** from `dist/windows/release-notes.md`:
    - the version, and "Windows port v1.0" when `-V1` is given;
    - "Unsigned. Windows SmartScreen shows 'Unknown publisher' (More info → Run anyway). Not supported with Smart App Control on" (R-M6-9);
    - install and portable notes;
    - the unit-test counts per group, and "ARM64: built (`aarch64-windows-gnu`); unit tests are an owner check" with the owner's result if given;
    - the SHA-256 of the bundled ConPTY files;
    - the checksums.
  - `release_channel` stays `tip` for `-win.<N>` builds (semver pre-release). At this plan's base it only shows in `+version` on Windows. The M5 19.n batch 2 "update channel" item may give it a meaning; Task 1's implementer re-checks that the updater still looks only at `N` (R-M5-9a).
- **R-M6-8 Signing hook, no certificate (gap).** Kept as the owner asked: plan the hook, sign manually.
  - Artifacts are unsigned by default.
  - `release.ps1 -SignCommand '<command with {file}>'` passes through to `package.ps1`, which signs `ghostty.exe` and `tmux.exe` in the stage before zipping. It never signs `conpty.dll`/`OpenConsole.exe`, which keep Microsoft's signature. It also gives ISCC `/DSign /Ssigntool=<command with $f>`, so `setup.exe` and the uninstaller (`SignedUninstaller=yes`) are signed.
  - The PDBs still match: signing does not change the code.
  - `package.ps1 -FromZip` repackages an existing zip without a build. Task 9 uses it for the test setup; the owner can use it to re-sign a release that was published unsigned, then `gh release upload --clobber` with a regenerated `SHA256SUMS.txt`.
- **R-M6-9 What M6 does not do** (v1.0 gaps, in the CHANGELOG):
  - **Install scope:** all-users (per-machine) install (owner decision 3); a PATH entry for external tmux (documented instead).
  - **Packaging formats:** MSIX and the Windows 11 top-level context menu; winget/scoop manifests.
  - **Signing:** no certificate. Consequences, stated in the README, notes and CHANGELOG (pre-flight I10):
    - **Smart App Control blocks the setup and the exe outright, with no "Run anyway".** It is on by default on clean Windows 11 22H2+ installs; turning it off is a one-way switch in Windows Security, so the port is "not supported with Smart App Control on".
    - Elsewhere SmartScreen warns about an unknown publisher on downloaded files.
  - **ARM64:** no automated unit tests (an owner check, non-blocking; owner decision 4); the backlog workflow would close it.
  - **Uninstall:** no jump-list removal (Explorer drops it when the shortcut is gone; the CLI has no COM, R-M5-5).
- **R-M6-10 Third-party notices** (owner decision 1; pre-flight I11).
  - `dist/windows/THIRD_PARTY_NOTICES.txt` ships at the zip root and in the install dir.
  - It lists every component compiled, linked or embedded into the Windows exes, or shipped beside them or under `share`, each with its licence name and full licence text:
    - **fonts:** JetBrains Mono, Nerd Fonts symbols;
    - **C/C++ libraries:** FreeType, HarfBuzz, zlib, libpng, oniguruma, simdutf, highway, wuffs, glslang, SPIRV-Cross, Dear ImGui;
    - **Zig packages:** every Zig package, **including the transitive ones** (the `build.zig.zon` of each package under `zig-pkg` reachable from the root);
    - **`pkg/*`:** the vendored C sources;
    - **share:** the iTerm2 colour schemes;
    - **bundled ConPTY:** microsoft/terminal (MIT, R-M6-12);
    - **toolchain runtimes, per arch:**
      - x64-msvc: Zig std and compiler_rt (MIT);
      - arm64-gnu adds LLVM libc++, libc++abi and libunwind (Apache-2.0 WITH LLVM-exception), the MinGW-w64 CRT, and winpthreads if linked.
  - `third-party-check.ps1` fails packaging when:
    - a dependency name, a toolchain-table entry for the arch, or `microsoft/terminal` has no `== <name> ==` section;
    - an exclusion lacks its reason (`gtk4_layer_shell: Linux only`).
- **R-M6-11 ARM64 release ABI is `aarch64-windows-gnu` by default** (lead ruling 2026-10-28, forced by the owner's machine; owner may overturn; amends DECISIONS R3 for the ARM64 artifacts, recorded by Task 10 for the owner's sign-off).
  - **Why.** The owner's VS 18 Build Tools have only the x86/x64 MSVC tools, and adding "MSVC ARM64 build tools" needs admin. `aarch64-windows-gnu` needs nothing extra, because Zig ships the MinGW-w64 libraries. M3–M5 proved it: the cross-build passed in each acceptance (M3 after `117aa103b`).
  - **x64 stays `x86_64-windows-msvc`.**
  - **`release.ps1 -Arm64Abi gnu|msvc`**, default `gnu`. `msvc` is the optional switch after the owner has added the VS component. Only then does the preflight check `vswhere -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64` and name the missing component.
  - The chosen ABI is printed in the notes.
  - **Consequences:**
    - **Symbols.** The gnu build is **expected to emit a PDB**: std.Build installs one for any non-stripped Windows LLVM build, whatever the ABI (pre-flight I3). `-NoPdbOk` is only a fallback: if it is ever needed, the arm64 symbols zip is left out and the notes say so.
    - **C runtime.** MinGW's C runtime, plus LLVM libc++ for the C++ dependencies, instead of the VC runtime. `tmux.exe` has no libc (`link_libc = false`) and is unaffected. The notices list them (R-M6-10).
    - **Tests.** The ARM64 test exe uses the same ABI, so the owner's device run tests what ships.
  - **Cost if wrong:** add the VS component (admin, one time) and pass `-Arm64Abi msvc`.
- **R-M6-12 Bundled ConPTY** (owner approval 2026-10-28; the feature is M5 work on `sdd/task-m5-conpty`: `windows-conpty = bundled|inbox`, build option `-Dconpty-dir`).
  - **What ships.** `conpty.dll` and `OpenConsole.exe` from NuGet `Microsoft.Windows.Console.ConPTY` **1.25.260930003** (MIT, signed by Microsoft), next to `ghostty.exe`, per arch.
  - **Install.** They are installed and uninstalled like the other files; the stage is the installer's source.
  - **Source.**
    - `release.ps1 -ConptyPackage <nupkg or extracted dir>` (required) gives each build `-Dconpty-dir=<arch dir>`. A `.nupkg` is extracted (it is a zip) into `<OutDir>\conpty\`.
    - No network: the owner downloads the package once (RELEASING step 1).
    - `package.ps1` copies both files from `<Prefix>\bin`.
  - **Integrity.**
    - The package version is checked.
    - Both files of both arches must have `Get-AuthenticodeSignature` = `Valid` with a Microsoft signer, in the preflight and again in the `package.ps1` verification.
    - Their SHA-256 values are recorded in `release.log` and the notes.
  - **Signing.** `-SignCommand` never touches them.
  - **Imports.** The `dumpbin` check of `ghostty.exe` is unchanged: ConPTY is loaded at runtime, not imported (the M5 conpty task owns that rule).
  - **Notices.** `microsoft/terminal` (MIT) in `THIRD_PARTY_NOTICES.txt` (R-M6-10).
  - **README.** It names both files and the `windows-conpty = inbox` fallback.
  - **Budget.** `OpenConsole.exe` is a separate process per surface. It is outside `ghostty.exe`'s Private Bytes, but is reported in the Task 11 RAM rows.

## Waves (parallelism)

≤ 3 tasks per wave; file sets inside a wave are strictly disjoint.

| Wave | Tasks | Depends on |
|---|---|---|
| W1 | 1 version helper + `win-` tags · 3 `--only-this-exe` · 4 `package.ps1`, `lib/Native.psm1`, privacy check, `README-windows.txt` | M5 accepted, M5 19.n `Config.zig` landed (1); — (3); M5 ConPTY landed (4) |
| W2 | 2 version resources, `tmux.pdb`, `skip_foreign_checks` · 5 Inno script + `installer/build.ps1` · 6 `package-portable.ps1` scenario | 1 (2); 3+4 (5); 4 (6) |
| G1 | **Lead batch** (below) | 2, 3, 5, 6 |
| W3 | 7 `installer-test.ps1` scenario · 8 `release.ps1`, `release-version.ps1`, notes template, `RELEASING.md` · 13 `THIRD_PARTY_NOTICES.txt` + check | 5 (7); 2+4+5+G1 (8, which needs G1's RAM number); 4 (13) |
| G2 | **Task 9 (lead):** `release.ps1 -Rehearsal` on the owner's machine; `E2E -Only package-portable,installer-test` on its output; 9.n fixes | 7, 8, 13 |
| W4 | 10 docs: CHANGELOG, SPEC, DECISIONS amendment lines, feature checklist, test README (alone) | 9.* |
| W5 | 11 release candidate, v1.0 acceptance, owner sign-off (lead + owner) | 10 |

**G1 (lead batch):**
1. `RFS -Dversion-string=<zon>-win.0 -Dconpty-dir=<x64 dir>` with a sampler running alongside. The sampler records, every second, the summed working set of `zig.exe`, `clang*.exe` and `lld*.exe` (`Get-Process`), and the lowest `FreePhysicalMemory`. Record the peak and the size of `zig-out\rfs\bin\ghostty.pdb` (pre-flight I8). Over what the machine can give → take R-M6-3's fallback before W3.
2. `PS dist/windows/package.ps1 -Prefix zig-out\rfs -Version <zon>-win.0 -Arch x64 -OutDir zig-out\g1 -Symbols -Installer`. The privacy check runs on a real `-Dstrip=false` PDB.
3. `GHOSTTY_E2E_PACKAGE=<that zip>` `E2E -Only explorer-cli,package-portable,dpi-sim`. A SKIP of a scenario whose input the lead provided counts as FAIL (pre-flight MINOR 21).
4. The test setup via `package.ps1 -FromZip … -Installer -Test`, then `GHOSTTY_E2E_SETUP=<…-setup-test.exe>` `E2E -Only installer-test` once Task 7 has landed (else in G2).

Hot-file chains (every file touched by more than one task):
- `dist/windows/package.ps1`: 4 → 13 → 9.n.
- `dist/windows/installer/ghostty.iss`: 5 → 9.n.
- `dist/windows/release.ps1`: 8 → 9.n.
- `test/windows/e2e.ps1` (`ValidateSet` += `M6`): 6 only.
- `test/windows/e2e/explorer-cli.ps1`: 3 only.
- `docs/windows/{SPEC.md, CHANGELOG.md, feature-checklist.md, DECISIONS.md}`, `test/windows/README.md`: 10 (+ Task 11 acceptance lines).

Interfaces fixed by this plan (so W2/W3 tasks run in parallel):
- **`dist/windows/lib/Native.psm1`** (Task 4):
  ```
  Find-GitBash      -> path or throw (both paths named)
  Invoke-Native -Exe <path> -Args <string[]> -Log <file> [-TimeoutSec <n>] -> exit code; never throws on stderr
  Get-FreeMemoryMB  -> int
  Test-Privacy -Path <file> -> $null or "<offset>: <context>" (rules in Task 4)
  ```
- **`package.ps1`** (Task 4):
  ```
  package.ps1 (-Prefix <dir with bin\ and share\> | -FromZip <zip>) -Version <v> -Arch x64|arm64 -OutDir <dir>
              [-Installer] [-Test] [-Symbols] [-NoPdbOk] [-SignCommand '<cmd {file}>'] [-AllowNoTic] [-NoConpty]
  ```
  - Writes `<OutDir>\ghostty-<v>-windows-<arch>.zip`, plus with `-Symbols` the `-symbols.zip` from `<Prefix>\bin\{ghostty,tmux}.pdb`.
  - With `-Installer`, calls `installer\build.ps1 -Stage <stage> -Version <v> -Arch <arch> -OutDir <OutDir> [-Test] [-SignCommand …]`.
  - Prints one `artifact: <path>` line per file. Exit 0, or 1 with the failed check.
- **`installer/build.ps1`** (Task 5): the parameters above.
  - It finds ISCC with R-M6-6's order and message (exit 2).
  - It writes `ghostty-<v>-windows-<arch>-setup[-test].exe`.
  - `build.ps1 -Probe` only looks for ISCC: exit 0 and the path, or exit 2.
- **`release-version.ps1`** (Task 8):
  ```
  release-version.ps1 -N <string> [-Rehearsal] [-RepoRoot <dir>]   # prints zon=…, version-string=…, tag=…, sha=…; exit 1 + rule
  release-version.ps1 -SelfTest
  ```
- **`release.ps1`** (Task 8):
  ```
  release.ps1 -N <string> -ConptyPackage <nupkg or dir> [-Rehearsal] [-V1] [-OutDir <dir>] [-Force]
              [-SignCommand '<cmd {file}>'] [-Arm64Abi gnu|msvc] [-Arm64TestExe] [-SkipTests] [-DryRun]
              [-Zig <path>] [-Lock <path>]
  ```
  - `-SkipTests` is refused without `-Rehearsal`.
  - `-DryRun` runs the preflight only and prints every later step's command line.
  - `-Lock` defaults to the agent test-lock; if it is missing, the steps run serially with the RAM gate.

---

### Task 1: `windows_version.zig`, `win-` tags in the build, one `-win.<N>` rule

**Review:** light.

**Files:**
- Create `src/build/windows_version.zig` (std only; imported by `build.zig`'s build module and by the main test exe).
- Modify:
  - `src/build/Config.zig`:
    - in the `if (vsn.tag) |tag|` branch, `switch (windows_version.tagKind(tag))`: `.tip, .fork` fall through to the dev version; `.upstream` keeps the `v<zon>` check;
    - before `std.SemanticVersion.parse(v)` of `-Dversion-string`, `windows_version.checkVersionString(v)` runs; its error becomes a build error naming the value (R-M6-1).
  - `src/apprt/win32/update/release.zig`: `currentN` returns `windows_version.winN(version)`. The test block gets `_ = windows_version;`, so the new tests run in the main test exe.

**Interfaces:**
- Produces:
  ```zig
  // src/build/windows_version.zig
  pub const TagKind = enum { tip, fork, upstream };
  pub fn tagKind(tag: []const u8) TagKind;                       // "tip" → tip; "win-" prefix → fork; else upstream
  pub fn winN(version: []const u8) ?u32;                         // "<zon>-win.<N>" at the very end, canonical digits only
  pub const Error = error{ BadWinSuffix, NTooLarge, WinWithBuildMetadata };
  pub fn checkVersionString(raw: []const u8) Error!void;          // the R-M6-1 text rule; no "-win." → ok
  pub fn fileVersion(v: std.SemanticVersion) [4]u16;              // {major, minor, patch, N or 0}; called after checkVersionString
  pub fn rcHeader(alloc: Allocator, v: std.SemanticVersion, debug: bool, exe: Exe) Allocator.Error![]u8;
  pub const Exe = enum { ghostty, tmux };                        // picks FileDescription / OriginalFilename
  ```
  `rcHeader` emits exactly these `#define`s: `GHOSTTY_FILEVERSION`, `GHOSTTY_VERSION_STR`, `GHOSTTY_FILEFLAGS`, `GHOSTTY_FILE_DESCRIPTION`, `GHOSTTY_ORIGINAL_FILENAME`. The version string is semver, so it needs no escaping; the function asserts `[0-9A-Za-z.+-]`.
- [ ] **Step 1: Failing tests** (in `windows_version.zig`):
  - `"windows version: tag kinds"`: `tip` → tip; `win-1.3.2-dev-3`, `win-x` → fork; `v1.3.2`, `foo` → upstream.
  - `"windows version: winN"`: `1.3.2-dev-win.3` → 3; `1.3.2-win.0` → 0; `-win.07`, `-win.+5`, `-win.1_0`, `-win.x`, `-win.` → null; `1.3.2-dev` → null; `1.3.2-dev-win.3+abc` → null.
  - `"windows version: version-string rule"`:
    - ok: `1.3.2-dev-win.7`, `1.3.2-dev` (no `-win.`);
    - `BadWinSuffix`: `1.3.2-dev-win.07`, `1.3.2-win.`;
    - `NTooLarge`: `1.3.2-win.65536`;
    - `WinWithBuildMetadata`: `1.3.2-dev-win.3+abc`.
  - `"windows version: fileVersion"`, with `SemanticVersion` values built in the test, not parsed: `{1,3,2,pre="dev-win.7"}` → `{1,3,2,7}`; `{1,3,2,pre="dev"}` → `{1,3,2,0}`.
  - `"windows version: rc header"`:
    - `1.3.2-dev-win.7`, ghostty, release: `#define GHOSTTY_FILEVERSION 1,3,2,7`, `#define GHOSTTY_VERSION_STR "1.3.2-dev-win.7"`, `#define GHOSTTY_FILEFLAGS 0x2L`, `"Ghostty"`, `"ghostty.exe"`;
    - tmux, Debug, `1.3.2`: `0x1L`, `"Ghostty tmux shim"`, `"tmux.exe"`.
  - `"win32 update: currentN delegates"`: the existing `currentN` cases still pass, and `1.3.2-dev-win.07` → null.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="windows version"` → FAIL (file missing).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify.**
  - `-Dtest-filter="windows version"` and `"win32 update"` pass; `LOCK ZIG build -j6` passes.
  - `LOCK ZIG build -h -Dversion-string=1.3.2-win.07` fails, naming the value.
  - Tag check without touching the shared refs (pre-flight MINOR 26):
    1. `git clone --local --no-checkout . zig-out/tagcheck`, then a checkout in it;
    2. `git -C zig-out/tagcheck tag win-0.0.0-0`;
    3. `LOCK ZIG build -h` there → exit 0;
    4. delete `zig-out/tagcheck`.

    The clone's tag never reaches the main repo.
- [ ] **Step 5: Commit** `git commit -m "build(windows): version helper, win- tags no longer panic the build, one -win.N rule"`

### Task 2: Version resources, `tmux.pdb`, foreign test exe

**Review:** light.

**Files:**
- Create:
  - `dist/windows/versioninfo.rc`: the VERSIONINFO block of R-M6-2. It uses numeric literals with the macro names in comments, `FILEFLAGSMASK 0x3FL`, `#include "ghostty_version.h"`, and the `GHOSTTY_*` macros; `ProductName` is a literal; `Translation 0x0409, 1200`.
  - `dist/windows/tmux.rc`: `#pragma code_page(65001)`, `LANGUAGE 0, 0`, the icon `1 ICON "ghostty.ico"`, `#include "versioninfo.rc"`. No manifest.
- Modify:
  - `dist/windows/ghostty.rc`: `#pragma code_page(65001)` first; the commented VERSIONINFO block replaced by `#include "versioninfo.rc"`; manifest and icon unchanged.
  - `src/build/GhosttyExe.zig`: on Windows, `b.addWriteFiles()` adds `ghostty_version.h` = `windows_version.rcHeader(…, .ghostty)`, passed as `include_paths` of `addWin32ResourceFile`.
  - `src/build/GhosttyTmuxShim.zig`: the same with `.tmux` and `dist/windows/tmux.rc`. `.strip = cfg.strip`; `cfg.strip` defaults to true for ReleaseFast, so default builds stay stripped. The module stays `link_libc = false`.
  - `build.zig`: `test_run.skip_foreign_checks = true;` next to `addRunArtifact(test_exe)`.
- [ ] **Step 1: Build check** (no Zig test can read a linked resource):
  - `LOCK ZIG build -j6 --prefix zig-out/ver -Dversion-string=1.3.2-dev-win.7`;
  - then, for both exes, `powershell -NoProfile -Command "(Get-Item zig-out/ver/bin/ghostty.exe).VersionInfo | Format-List *"`.

  Before the change, FileVersion is empty → FAIL.
- [ ] **Step 2: Implement** R-M6-2 and the two build lines.
- [ ] **Step 3: Verify.**
  - Both exes show:
    - FileVersion `1.3.2-dev-win.7`; FileMajorPart…FilePrivatePart `1 3 2 7`; ProductVersion `1.3.2-dev-win.7`;
    - ProductName with the em dash intact (compared with `[char]0x2014`);
    - the FileDescription and OriginalFilename per exe;
    - IsPreRelease `True`, IsDebug `True` (Debug build).
  - `ghostty.exe` keeps its manifest and icon (the manifest is covered by `dpi-sim` in G1).
  - `LOCK ZIG build -j6 --prefix zig-out/ver -Doptimize=ReleaseFast -Dstrip=false -Dtarget=x86_64-windows-msvc` installs `tmux.pdb`.
  - `LOCK ZIG build test -j6 -Demit-test-exe -Dtarget=aarch64-windows-gnu -Dtest-filter="windows version"` installs `ghostty-test.exe` for arm64 and exits 0 (the run step is skipped).

    This is a debug-sized test compile through the lock; nothing else runs meanwhile.
  - A plain `LOCK ZIG build -j6` gives FilePrivatePart `0`.
  - Delete `zig-out/ver`.
- [ ] **Step 4: Commit** `git commit -m "build(windows): version resource and icon in both exes, tmux.pdb with -Dstrip=false, foreign test exe installs"`

### Task 3: `+uninstall-explorer-integration --only-this-exe`

**Review:** opus (what an uninstaller deletes, R-M6-5).

**Files:**
- Modify:
  - `src/os/windows_explorer.zig`: `ownsKeyFor`.
  - `src/cli/explorer_integration.zig`:
    - `UninstallOptions.@"only-this-exe": bool = false` and its help text;
    - the uninstall path passes the own exe path (`std.process.executablePath`, normalised per R-M6-5) when the flag is set;
    - the `--dry-run` line.
  - `test/windows/e2e/explorer-cli.ps1`: one dry-run case with the flag.

**Interfaces:**
- Produces:
  ```zig
  // windows_explorer.zig
  pub const PathEql = *const fn (a: []const u8, b: []const u8) bool;  // the CLI: normalise both (R-M6-5) + CompareStringOrdinal(ignoreCase); tests: an ASCII fold
  pub fn ownsKeyFor(command: ?[]const u8, menu: ?[]const u8, exe: ?[]const u8, eql: PathEql) bool;
      // exe null → ownsKey(command, menu) (R-M5-5); else the command's first quoted token must eql exe
      // (a key with no command but our menu text still counts: a failed install of this exe)
  ```
- [ ] **Step 1: Failing tests:**
  - `"windows explorer: only-this-exe owns only the same exe"`:
    - the command of `C:\A\ghostty.exe` vs exe `c:\a\GHOSTTY.EXE` → true;
    - vs `C:\B\ghostty.exe` → false;
    - exe null → the M5 answers;
    - an unquoted or empty command → false.
  - `"explorer cli: --only-this-exe deletes its own verbs and keeps a foreign one"` (pre-flight I9). In a private hive (`RegLoadAppKeyW`, M5 pattern), with test mode on:
    1. Run the CLI install from the running test exe (its path from `std.process.executablePath`), so the three verbs name it. Uninstall with the flag → all three deleted.
    2. Seed the three verbs naming `C:\Other\ghostty.exe`. Uninstall with the flag → all three kept, exit 0, one `kept (other ghostty.exe)` line per key. Without the flag → deleted.
    3. The hive files are removed at the end.
  - `"explorer cli: only-this-exe matches a short or prefixed path"`: the own path given as `\\?\<path>` and as its 8.3 form (if the volume has 8.3 names; else skipped) → still ours.
  - `"explorer cli: dry-run uninstall --all --only-this-exe"`: prints the `delete … if its command names <exe>` lines and the AUMID/icon lines, and opens no key.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="windows explorer"` and `"explorer cli"` → FAIL.
- [ ] **Step 3: Implement** R-M6-5.
- [ ] **Step 4: Verify:** both filters pass; `LOCK ZIG build -j6`; the scenario parses; `E2E -Only explorer-cli` (no window; the implementer may run it, M5 exception).
- [ ] **Step 5: Commit** `git commit -m "feat(cli): +uninstall-explorer-integration --only-this-exe keeps other copies' verbs"`

### Task 4: `package.ps1`, `lib/Native.psm1`, privacy check, portable layout

**Review:** opus (privacy of published files).

**Files:** Create `dist/windows/package.ps1`, `dist/windows/lib/Native.psm1` (interfaces above) and `dist/windows/README-windows.txt`.

**What `package.ps1` does, in order** (each failure prints `package: FAIL <check>` and exits 1):
1. **Stage** `<OutDir>\stage\ghostty-<v>-windows-<arch>\`:
   - from `-Prefix`: `bin\ghostty.exe`, `bin\tmux.exe`, `bin\conpty.dll` and `bin\OpenConsole.exe` (required unless `-NoConpty`, which `release.ps1` never passes), the `share` allowlist of R-M6-3, repo `LICENSE`, `README-windows.txt`, and `THIRD_PARTY_NOTICES.txt` once Task 13 lands;
   - or from `-FromZip`: extract, then the same checks.
2. **Verify:**
   - the required files of R-M6-3;
   - VersionInfo of both exes: ProductVersion = `-Version`; FilePrivatePart = `N` or 0; ProductName as R-M6-2 (built with `[char]0x2014`);
   - `-Version`: `release-version`'s text rule (`-win.(0|[1-9][0-9]*)$`, no `+`);
   - the ConPTY files: present, and `Get-AuthenticodeSignature` `Valid` with a Microsoft signer (R-M6-12);
   - imports, if `dumpbin.exe` is found through `vswhere`: `ghostty.exe` imports neither `winhttp.dll` nor `dbghelp.dll` (M5); `tmux.exe` imports only `KERNEL32.dll`/`ntdll.dll` (M4). Not found → `package: SKIP imports (no dumpbin)`;
   - with `-Installer`: the AUMID string and the `TrayClass` in `installer\ghostty.iss` equal the release `aumid` literal in `src/os/windows_explorer.zig` and the `class_name` literal in `src/apprt/win32/tray.zig`.
3. **Privacy** (pre-flight C1). `Test-Privacy` scans every staged file, every PDB, and later the setup exe, `release-notes.md` and `SHA256SUMS.txt`:
   - needles: `$env:USERNAME` and `$env:USERPROFILE`, ASCII and UTF-16LE, case-insensitive. A user name shorter than 4 characters is searched only as `\Users\<name>`, to avoid false hits;
   - a hit → `package: FAIL privacy <file> @<offset>: <40 bytes of context>`;
   - the compressed payload of the setup cannot hide a hit, because its input files were scanned in the stage.
4. **Sign** with `-SignCommand`: `{file}` is replaced by each of `ghostty.exe` and `tmux.exe`; a non-zero exit fails.
5. **Zip** (forward-slash entries, Global Constraints), then a check that every entry starts with `ghostty-<v>-windows-<arch>/` and contains no `\`.
6. **Symbols** with `-Symbols`: `ghostty.pdb` and `tmux.pdb` from `<Prefix>\bin`, privacy-scanned. Missing → FAIL, unless `-NoPdbOk` (then one `package: SKIP symbols` line).
7. **Installer** with `-Installer`: call `installer\build.ps1`, then privacy-scan the setup. Exit 2 (no ISCC) passes through.
8. Print the `artifact:` lines; remove `stage`.

**`README-windows.txt`** (plain ASCII, ≤ 80 columns):
- what this is (the unofficial port, a link to the fork);
- **unsigned:** Smart App Control blocks it; not supported with SAC on. SmartScreen: More info → Run anyway (R-M6-9);
- portable use: run `ghostty.exe` from the folder, which needs `share`, `conpty.dll` and `OpenConsole.exe` next to it; `windows-conpty = inbox` as the fallback;
- the config at `%USERPROFILE%\.config\ghostty\config.ghostty`; the data at `%LOCALAPPDATA%\ghostty` (logs, crash dumps, update state);
- Explorer integration: `ghostty.exe +install-explorer-integration`, reverted with `ghostty.exe +uninstall-explorer-integration --all --only-this-exe` (pre-flight MINOR 23). Portable copies run this before deleting the folder;
- `tmux.exe`, and the folder on PATH for the external tmux mode;
- `auto-update = off`;
- where the CHANGELOG is.

- [ ] **Step 1: Failing checks.**
  - **Missing terminfo** (pre-flight MINOR 20): a synthetic prefix `zig-out\pkgtest` (a copy of `zig-out\bin` and `zig-out\share` without `share\terminfo\78`) must exit 1 with `package: FAIL share\terminfo\78\xterm-ghostty`.
  - **`Test-Privacy -SelfTest`:** files with the user name in ASCII, in UTF-16LE, and in mixed case → hit; a file without it → no hit; a 3-letter name only in `\Users\<name>` form.
  - Before the scripts exist → FAIL trivially.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Verify:**
  - parse checks; the self-tests;
  - the Debug `zig-out` with `-AllowNoTic -NoConpty`:
    - the zip exists and has one top folder with `/` entries, `LICENSE` and `README-windows.txt`, and no `.pdb`;
    - the privacy scan **fails** on the Debug PDB (`-Symbols`), as the review found. This proves the check bites;
  - an empty `-Prefix` → exit 1 with `ghostty.exe`;
  - `-FromZip <that zip>` → the same zip contents;
  - delete the scratch dirs.

  The VersionInfo and ConPTY checks pass only once Task 2 and the M5 ConPTY work have landed; G1 covers them, and the report says which ran.
- [ ] **Step 4: Commit** `git commit -m "build(windows): package.ps1 stages, verifies, privacy-scans and zips the portable build"`

### Task 5: Inno Setup installer

**Review:** opus (what the installer and uninstaller write and delete, R-M6-4).

**Files:** Create `dist/windows/installer/ghostty.iss` and `dist/windows/installer/build.ps1` (interface above).

**`ghostty.iss` structure.** Preprocessor defines come from `build.ps1`: `AppVersion`, `Arch` (`x64`/`arm64`), `Stage`, `OutDir`, and optionally `GhosttyTest` and `Sign`.
- `#define AppAumid "com.mitchellh.ghostty.windows-unofficial"` and `#define TrayClass "GhosttyTray"` (both checked by Task 4).
- `[Setup]`:
  - `AppName=Ghostty`, `AppVerName=Ghostty {#AppVersion} (unofficial Windows port)`, `AppVersion`, `AppPublisher=Ghostty Windows port (unofficial)`, `AppPublisherURL=https://github.com/Denmurzik/ghostty`;
  - every R-M6-4 key;
  - `Compression=lzma2/max`, `SolidCompression=yes`, `OutputBaseFilename=ghostty-{#AppVersion}-windows-{#Arch}-setup` (`-test` suffix), `UsedUserAreasWarning=no`;
  - `VersionInfoVersion` = the 4-part FILEVERSION (from `build.ps1`);
  - `#ifdef Sign` → `SignTool=signtool` and `SignedUninstaller=yes`;
  - `#ifdef GhosttyTest` → the R-M6-4 test keys.
- `[Tasks]` `explorer` and `desktopicon`, both `Flags: unchecked`, under `#ifndef GhosttyTest`.
- `[InstallDelete]` the two dirs of R-M6-4.
- `[Files]` `Source: "{#Stage}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs`.
- `[Icons]` per R-M6-4, under `#ifndef GhosttyTest`.
- `[Run]` "Launch Ghostty" with `WorkingDir: {%USERPROFILE}` (`postinstall nowait skipifsilent`).
- `[UninstallRun]` per R-M6-4 (the same in both variants).
- `[Code]` under `#ifndef GhosttyTest`: the Explorer step, `PrepareToInstall` and `InitializeUninstall` of R-M6-4.

**`build.ps1`:** derives `VersionInfoVersion` with the Task 4 rule, runs `ISCC /Q /DAppVersion=… /DArch=… /DStage=… /DOutDir=… [/DGhosttyTest] [/DSign /Ssigntool=<cmd with $f>] ghostty.iss` through `Invoke-Native`, and prints `artifact:`.

- [ ] **Step 1: Self-test** `build.ps1 -SelfTest`: pure checks of the ISCC argument list for x64, arm64, test and sign (no ISCC needed). Before implementation → FAIL.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Verify:**
  - parse check; `-SelfTest`;
  - `build.ps1 -Probe` finds `%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe` (owner decision 2). With `$env:ISCC` set to a missing file → exit 2 with the R-M6-6 message;
  - ISCC compiles the release and the test variant, x64 and arm64, from a Task 4 stage (an `-AllowNoTic -NoConpty` stage is fine). Install nothing; delete the outputs.
- [ ] **Step 4: Commit** `git commit -m "build(windows): per-user Inno Setup installer with AUMID shortcut, running-app guards and opt-in Explorer integration"`

### Task 6: e2e `package-portable.ps1` (milestone M6)

**Review:** light.

**Files:**
- Create `test/windows/e2e/package-portable.ps1` (header `# e2e: milestone=M6 timeout=180 order=1000`).
- Modify `test/windows/e2e.ps1`: `ValidateSet` += `M6`, and the help text.

**Scenario:**
- **Input** `GHOSTTY_E2E_PACKAGE=<zip>`; unset → SKIP `no package (set GHOSTTY_E2E_PACKAGE)`.
- **MOTW.** Add `Zone.Identifier` (`[ZoneTransfer]` / `ZoneId=3`) to a copy of the zip, and extract that copy, so the files carry MOTW like a browser download (pre-flight I10).
- **Extract** into `<sandbox>\Portable <Ж>\`, with the name built from `[char]0x0416`.
- **CLI checks:** `ghostty.exe +version` (stdout redirected) prints the zip's version; `+list-themes --plain` prints ≥ 100 lines (resources found).
- **Session.** Launch the extracted `ghostty.exe --class=<class>` with the sandbox env and `command = direct:cmd.exe /k` in the sandbox config. In the shell, through the M3 typed-input helper (oracle: the IPC `state`/screen text, as in M5 `term-terminfo.ps1`):
  - `echo %GHOSTTY_RESOURCES_DIR%` → under the extracted folder;
  - `echo %TERM%` → `xterm-ghostty`;
  - `where tmux` → the first line is the extracted `tmux.exe`.

  `conpty.dll` and `OpenConsole.exe` are in the extracted folder. When `windows-conpty` resolves to `bundled`, the child `OpenConsole.exe` runs from that folder (`Win32_Process.ExecutablePath`; R-M6-12).
- **Close,** and assert that the process tree is gone.
- **Moved share:** rename `share` to `share.off` and launch → `TERM=xterm-256color` and one warning line in the sandbox log, no crash; rename it back.
- **No writes:** nothing new appeared in the extracted folder (file list before and after).

- [ ] **Step 1:** Write the scenario; make it parse; `E2E -Only package-portable` without the env → SKIP (the implementer may run this SKIP path; no window).
- [ ] **Step 2: Commit** `git commit -m "test(windows): e2e package-portable runs the zip from a spaced Cyrillic path with Mark-of-the-Web"`

### Task 7: e2e `installer-test.ps1` (milestone M6)

**Review:** opus (owner safety: the only installer run on the owner's machine outside the manual checks).

**Files:** Create `test/windows/e2e/installer-test.ps1` (`# e2e: milestone=M6 timeout=300 order=1001`).

**Scenario:**
- **Guards.** Input `GHOSTTY_E2E_SETUP=<…-setup-test.exe>`. SKIP if it is unset, if its name does not end in `-setup-test.exe`, or if its VersionInfo `FileDescription` is not `Ghostty test installer` (pre-flight MINOR 22). These guards ensure it is never the real installer.
- **Read-only snapshot** (`reg query`, no writes) of:
  - `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall` (subkey names);
  - the three `HKCU\Software\Classes\…\shell\GhosttyOpenHere` keys;
  - `HKCU\Software\Classes\AppUserModelId\com.mitchellh.ghostty.windows-unofficial*`;
  - the Start-menu `Programs` folder listing.
- **Env** for every process below: the sandbox env, plus `GHOSTTY_WIN32_TEST_IPC=1` and `GHOSTTY_WIN32_TEST_HIVE=<sandbox>\hive.dat` (pre-flight I9).
- **Install:** `setup /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOICONS /DIR="<sandbox>\Inst <Ж>" /LOG="<sandbox>\setup.log"`. Wait ≤ 120 s.
- **Assert after install:**
  - the files = the stage list + `unins000.exe`, `unins000.dat`;
  - `+version` → the version;
  - a GUI start with `--class` shows a window; close it.
- **Seed:**
  - `<inst>\ghostty.exe +install-explorer-integration` (same env), so the hive holds the installed exe's three verbs;
  - an AUMID key in the hive, through the same CLI's test hook or a direct `RegLoadAppKeyW` write;
  - a toast-icon file in the sandbox `LOCALAPPDATA\ghostty`;
  - `user-note.txt` in the install dir; a config sentinel in the sandbox config.
- **Uninstall:** `unins000.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=…`, same env. The uninstaller re-launches itself from `%TEMP%`, so wait until `unins000.exe` is gone (≤ 60 s, poll every 500 ms).
- **Assert after uninstall:**
  - the hive (read through an `Add-Type` P/Invoke of `RegLoadAppKeyW`/`RegOpenKeyExW`) has none of the three verbs and no AUMID key;
  - the toast icon is gone;
  - only `user-note.txt` remains in the install dir; the config sentinel is intact;
  - the real-`HKCU` snapshot equals the one before.
- **Hive unavailable:** if the hive cannot be opened → SKIP, never PASS.
- **`finally`:** kill own processes; delete the sandbox dirs and the hive files.

- [ ] **Step 1:** Write it; make it parse; the SKIP path runs without a window.
- [ ] **Step 2: Commit** `git commit -m "test(windows): e2e installer-test installs and uninstalls the test installer against an app hive"`

### Task 8: Local release script, tag validation, notes, `RELEASING.md`

**Review:** opus (release integrity, owner safety on a low-RAM machine, R-M6-6/7).

**Files:** Create:
- **`dist/windows/release-version.ps1`** (interface above). It reads:
  - `build.zig.zon` with a regex on `.version = "…"`;
  - `git tag -l "win-*"`, `git status --porcelain`, `git rev-parse HEAD`;
  - `git merge-base --is-ancestor HEAD origin/windows`.

  No network. `-SelfTest` runs the pure table:
  - a valid case;
  - `N` = `07`, `+5`, `65536`, `0` without `-Rehearsal`;
  - `-Rehearsal` with `N ≠ 0`;
  - a zon mismatch;
  - `N` not above the existing max;
  - a duplicate `N`.
- **`dist/windows/release.ps1`** (interface above). It uses `lib/Native.psm1` throughout: Git Bash by full path for the test-lock; `Invoke-Native` for every `zig`, `git` and ISCC call; `ZIG_GLOBAL_CACHE_DIR=<repo>\zig-out\zig-global` for every build and test step. Each step prints `== <n>/<total> <name>`, appends to `<OutDir>\release.log`, and stops the run on failure, naming the step. Steps in order:
  1. **Preflight:**
     - `release-version.ps1`;
     - `OutDir` (default `zig-out\release\<version>`) is absent, or `-Force`; `git check-ignore` confirms it is ignored;
     - Zig found; the test-lock found (else the serial mode, logged);
     - `tic.exe`, ISCC (`installer\build.ps1 -Probe`) and Git Bash found;
     - the ConPTY package: version, files and signatures (R-M6-12);
     - with `-Arm64Abi msvc` only: the VS ARM64 component;
     - free memory ≥ the gate (G1's number, a constant in the script with the G1 date in a comment).
  2. **Unit tests:** the three groups of R-M6-6, then `test-tmux-shim`, each `zig build test -j6 --summary all …` through the lock, with a 1500 s timeout and the RAM gate before it. The pass/skip/fail counts are parsed from the `--summary all` lines and written to `tests.txt`.
  3. **Build x64:** `zig build -j4` with the R-M6-3 flags, `--prefix <OutDir>\prefix-x64`, `-Dconpty-dir=<the package's x64 dir>`.
  4. **Build arm64:** the same with `aarch64-windows-<abi>`, `--prefix <OutDir>\prefix-arm64` and the arm64 dir. With `-Arm64TestExe`, then the ARM64 test exe of R-M6-6, zipped as `ghostty-<v>-windows-arm64-tests.zip`, which is not in `SHA256SUMS.txt` or `publish.txt`.
  5. **Package:** `package.ps1 -Prefix … -Installer -Symbols [-SignCommand …]` per arch, into `<OutDir>`.
  6. **Check:** `<OutDir>\prefix-x64\bin\ghostty.exe +version` prints the version.
  7. **Sums:** `SHA256SUMS.txt` (`Get-FileHash`, lower-case hex, two spaces, file name), written to a temp file and renamed when complete.
  8. **Notes:** `release-notes.md` from the template (counts from `tests.txt`, no local paths), then privacy-scanned together with `SHA256SUMS.txt`.
  9. **Publish commands** per R-M6-7, printed and written to `publish.txt`. Nothing is executed. The prefixes are removed.

  `-DryRun` runs step 1 and prints steps 2–9 with their exact command lines.
- **`dist/windows/release-notes.md`:** a template with `{{VERSION}}`, `{{TAG}}`, `{{V1_LINE}}`, `{{TESTS}}`, `{{ARM64_LINE}}`, `{{CONPTY}}`, `{{SHA256SUMS}}`, and the fixed R-M6-9 signing text.
- **`docs/windows/RELEASING.md`**, the owner's runbook:
  1. **One-time setup:**
     - `gh auth login`;
     - `gh repo view Denmurzik/ghostty --json visibility` → `PUBLIC` (the update check and downloads need it; pre-flight MINOR 28);
     - disable the upstream workflows in the fork's Actions settings (MINOR 30);
     - download `Microsoft.Windows.Console.ConPTY` 1.25.260930003 (`.nupkg`);
     - Inno Setup is already installed; the VS ARM64 component only for `-Arm64Abi msvc` (admin).
  2. **Push first:** `git push origin windows` (`--force-with-lease` after a rebase), then `git fetch --tags origin`; the next `N`; the CHANGELOG entry (pre-flight I7).
  3. `PS dist/windows/release.ps1 -N <N> -ConptyPackage <nupkg> [-V1] [-Arm64TestExe]`. It takes about 1–2 h; run no other builds meanwhile.
  4. Smoke the local artifacts (the owner part of § M6 exit checklist), including MOTW and Smart App Control.
  5. Optional signing (R-M6-8).
  6. Run `publish.txt` in PowerShell; check the draft page; publish.
  7. Check the update toast from the installed older build.
  8. **A bad release:** delete the GitHub release only; **keep the tag** (its `N` is burned); release `N+1`.

- [ ] **Step 1:**
  - `release-version.ps1 -SelfTest` → FAIL before implementation;
  - `release.ps1 -DryRun -N 1 -ConptyPackage <x>` → FAIL before implementation.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Verify:**
  - parse checks; `-SelfTest`;
  - `release.ps1 -Rehearsal -N 0 -ConptyPackage <path> -DryRun` on this machine: the preflight passes or names exactly what is missing. The printed command lines match the R-M6-3 flags (with `ZIG_GLOBAL_CACHE_DIR`, `-j4`, `--summary all`) and the R-M6-7 commands (marked REHEARSAL, one PowerShell line each);
  - with `-Lock` pointing to a missing file → the dry run says `serial mode`;
  - `release.ps1 -N 1 -SkipTests -DryRun …` → refused for `-SkipTests` alone;
  - `git grep -n "gh release\|git push" dist/windows/*.ps1` shows them only inside printed strings;
  - `git grep -nP "[^\x00-\x7F]" dist/windows/*.ps1 dist/windows/lib/*.psm1 dist/windows/installer/*.ps1` → nothing.
- [ ] **Step 4: Commit** `git commit -m "build(windows): local release script with tag validation, unit groups, privacy, sums, notes and printed publish commands"`

### Task 9: Release rehearsal on the owner's machine (lead) and 9.n fixes

**Files:** none planned. Each 9.n touches only the files its note names (Task 4/5/8/13 files).

- [ ] **Step 1:** Preflight only. ISCC is installed (owner decision 2); ARM64 uses `gnu` (R-M6-11); the ConPTY package is downloaded (ask the owner if not).
- [ ] **Step 2:** `PS dist/windows/release.ps1 -Rehearsal -N 0 -ConptyPackage <pkg> -Arm64TestExe` (no `-SkipTests`), started with `run_in_background`. Record the wall time per step and the lowest free memory seen.
- [ ] **Step 3:** On its output:
  - `GHOSTTY_E2E_PACKAGE=<x64 zip>` `E2E -Only package-portable`;
  - the test setup: `PS dist/windows/package.ps1 -FromZip <x64 zip> -Version <zon>-win.0 -Arch x64 -OutDir zig-out\release\rehearsal-test -Installer -Test`, then `GHOSTTY_E2E_SETUP=<…-setup-test.exe>` `E2E -Only installer-test`;
  - the arm64 zip, setup and symbols listing, and its VersionInfo (no run);
  - the privacy scan passed for every artifact (`release.log`).
- [ ] **Step 4 (owner, optional now, required before Task 11):** install the rehearsal's **real** x64 setup (`<zon>-win.0`) on the owner's account. It is the base for the `N → N+1` upgrade test, and it is the "older build" that later shows the update toast (pre-flight I6).
- [ ] **Step 5:** For each failure, a 9.n note: step, log excerpt (no user name), evidence. Fix, then re-run the failing step or the rehearsal. Commits `git commit -m "fix(release): <summary>"`.

### Task 10: Docs — CHANGELOG, SPEC, DECISIONS amendments, feature checklist, test README

**Review:** lead.

**Files:** Modify:
- `docs/windows/CHANGELOG.md`: an M6 section with:
  - what ships and the artifact names;
  - install/portable/uninstall behaviour; the version scheme; the local release path;
  - the gaps of R-M6-9, with the Smart App Control text verbatim;
  - the backlog line "optional `workflow_dispatch`-only `windows-ci.yml` with ARM64 unit tests".
- `docs/windows/SPEC.md`:
  - §13 as built: names, layout, installer keys and guards, `--only-this-exe`, tag `win-*`, the local release script and the printed publish, the signing hook, the bundled ConPTY. This replaces "tag `v*`" and the CI line;
  - §3: the release flags with `-Dstrip=false`, `-j4`, the neutral global cache;
  - §16 R15/R16: the outcome;
  - §17 M6: plan link, then "done" in Task 11;
  - §18: R-M6-1…12.
- `docs/windows/DECISIONS.md` "Release", two dated lines (pre-flight MINOR 24):
  - "2026-10-28 (owner): releases are built locally with `dist/windows/release.ps1`; GitHub Actions is optional and manual-only";
  - "2026-10-28 (lead ruling, owner sign-off pending in the M6 acceptance): ARM64 release artifacts use `aarch64-windows-gnu` (amends R3); `-Arm64Abi msvc` once the VS ARM64 component is installed".
- `docs/windows/feature-checklist.md`: rows for zip, installer, version resource, release script, notices, bundled ConPTY; every row `done`, `manual` or a gap.
- `test/windows/README.md`: the M6 scenarios and their env (`GHOSTTY_E2E_PACKAGE`, `GHOSTTY_E2E_SETUP`), the installer safety rule, and "SKIP with the lead's input = FAIL".
- [ ] **Step 1:** Write. **Step 2: Commit** `git commit -m "docs(windows): M6 release docs, SPEC packaging as built, local release path"`

### Task 11: Release candidate, v1.0 acceptance, owner sign-off

**Review:** lead + owner.

- [ ] **Step 1:** Upstream rebase per SPEC §17, if the lead takes it now (the zon, and so the tag's `<zon>`, may change).
- [ ] **Step 1a (owner):** `git push origin windows` (`--force-with-lease` after a rebase), then `git fetch --tags origin` (pre-flight I7).
- [ ] **Step 2 (owner, or the lead with the owner's go; local):** `PS dist/windows/release.ps1 -N 1 -V1 -ConptyPackage <pkg> -Arm64TestExe`. The output dir holds 6 artifacts (5 with `-NoPdbOk`), `SHA256SUMS.txt`, `release-notes.md` and `publish.txt`.
- [ ] **Step 3 (lead, owner's machine, the usual lock):**
  - Extract the x64 zip to `zig-out\rc`, set `GHOSTTY_E2E_EXE=…\ghostty.exe`, and run `E2E -Milestone all`. All green; SKIPs only for documented reasons. It includes `package-portable` and `installer-test` on this RC (a test setup made from its zip).
  - `test/windows/vt-smoke.ps1` against the RC exe (the DECISIONS "vttest-style checks"; pre-flight MINOR 27).
  - The RAM/latency rows of § budget (`m6-rc` rows in the CSVs), compared with the recorded M5 rows.
  - `test/windows/claude-team.ps1` against the RC (as in M4; the owner's login; the owner's go for the token cost).
- [ ] **Step 4 (owner):** the manual lines of § M6 exit checklist, on the **local** artifacts, then the "after publishing" lines.
- [ ] **Step 5:** Record `docs/windows/m6/acceptance.md`.
  - It states that "upstream tests on Windows" means unit group 3's four filters.
  - It records the owner's sign-off on R-M6-11 (the DECISIONS line).
  - Amend SPEC §17 (M6 done) and the CHANGELOG acceptance line.

  Commit `git commit -m "docs(windows): M6 acceptance — Windows port v1.0"`.
- [ ] **Step 6 (owner):** push the acceptance commit; run `publish.txt` (tag, push the tag, `gh release create … --prerelease --draft`); check the draft; publish. Then the "after publishing" checks.

### Task 13: `THIRD_PARTY_NOTICES.txt` and its coverage check

**Review:** light (the lead reads the licence list).

**Files:**
- Create `dist/windows/THIRD_PARTY_NOTICES.txt` and `dist/windows/third-party-check.ps1`.
- Modify `dist/windows/package.ps1`: stage the file at the zip root; add it to the required files; run the check (with the arch) before zipping.

- [ ] **Step 1: Failing check.** `third-party-check.ps1 -RepoRoot . -Arch x64` → exit 1 (file missing).
  - The check reads the dependency names of `build.zig.zon` and, recursively, of every package's `build.zig.zon` under `zig-pkg` reachable from the root, plus `pkg/*`.
  - It adds the fixed toolchain table for the arch (R-M6-10) and `microsoft/terminal`.
  - Each name needs a `== <name> ==` section, or an exclusion with a one-line reason.
  - `-SelfTest` covers: a section present; an exclusion; a missing name → fail; a missing arm64 toolchain entry → fail for `-Arch arm64` only.
- [ ] **Step 2: Decide what ships.**
  - Find what the Windows exes really compile, link or embed:
    - `src/build/SharedDeps.zig` and `GhosttyTmuxShim.zig` (`tmux.exe` is std only);
    - the embedded fonts in `src/font/embedded.zig`;
    - the `share` content (iTerm2 colour schemes);
    - for arm64-gnu, the linker's `--verbose-link` output on one arm64 build (libc++/libc++abi/libunwind, MinGW CRT, winpthreads?).
  - Everything else goes in the exclusion table with its reason, for example: GTK/Wayland/fontconfig/`gtk4_layer_shell`/`libintl` Linux only; `macos`/`zig_objc`/`apple_sdk` macOS only; `android_ndk`; `zig_js`; `translate_c` build-time only; `sentry` if not linked on Windows.
- [ ] **Step 3: Write the file** (ASCII/UTF-8 without BOM):
  - a header naming the port, a pointer to Ghostty's own MIT `LICENSE`, and the date;
  - one section per component: name, version or commit (from the zon files), upstream URL, licence name, and the full licence text, copied from the fetched package (`zig-pkg`/the Zig cache), from `src/font/res/{OFL,MIT}.txt`, or from the LLVM/MinGW-w64 sources shipped with Zig 0.17;
  - no local paths.
- [ ] **Step 4: Verify:**
  - parse checks; `-SelfTest`;
  - the check passes on the repo for both arches;
  - `package.ps1` on the Debug `zig-out` with `-AllowNoTic -NoConpty` → the zip has `THIRD_PARTY_NOTICES.txt` at its root;
  - the Task 5 installer installs it automatically (the stage is the source).
- [ ] **Step 5: Commit** `git commit -m "build(windows): third-party notices shipped in the zip and installer, with a coverage check"`

## M6 exit checklist (v1.0 gate; owner signs, PASS/FAIL per line)

1. **Release run.**
   - `release.ps1 -N 1 -V1` finished with the three unit groups and `test-tmux-shim` green (`tests.txt` with counts).
   - Both arches built and packaged: 6 artifacts (5 with `-NoPdbOk`) and `SHA256SUMS.txt` matching them.
   - **The privacy scan passed for every artifact.**
   - `publish.txt` names the built commit.
   - The wall time and the RAM low point are recorded.
2. **Version.**
   - `+version` of the RC prints `<zon>-win.1`.
   - Properties → Details of both exes (x64 and arm64) shows FileVersion `<maj>.<min>.<patch>.1`, ProductName `Ghostty — Unofficial Windows port`, and the icon.
   - A local build at the tagged commit does not panic and is not `-win.`.
3. **e2e and vttest.** `E2E -Milestone all` green on x64 with the RC exe: the M1–M6 scenarios, with `package-portable` on the RC zip and `installer-test` on a test setup made from it. `vt-smoke.ps1` against the RC exe green.
4. **Budgets.** The RC rows within § RAM and latency budget.
5. **Claude Code.** The `claude-team.ps1` agent-team run passes against the RC (DECISIONS v1.0 gate).
6. **Feature checklist** closed: every row done, manual or a documented gap (DECISIONS v1.0 gate). "Upstream tests on Windows" = unit group 3, as stated in the acceptance record.
7. **ARM64** (owner checks; recorded, never blocking; owner decision 4): built and packaged (line 1); the `-arm64-tests.zip` test exe run on an ARM64 device (exit code), or N/A.
8. **Third-party notices.** `THIRD_PARTY_NOTICES.txt` is at the zip root and in the install dir; `third-party-check.ps1` passed for both arches (owner decision 1).
9. **Owner manual checks** (x64, the owner's real account).

   **Before publishing, on the local artifacts.** Copy the setup and the zip, and give the copies MOTW (`Zone.Identifier`, `ZoneId=3`) as RELEASING.md shows:
   - **Smart App Control.** Record whether it is on (Windows Security → App & browser control). If it is on, record that the setup is blocked (expected, R-M6-9) and do the rest on a machine or VM with it off.
   - **Install** (from the MOTW copy). SmartScreen shows "Unknown publisher" → More info → Run anyway. No UAC prompt; it installs to `%LOCALAPPDATA%\Programs\Ghostty`; there is a Start-menu entry; "Launch Ghostty" opens a window in `%USERPROFILE%`.
   - **Upgrade `N → N+1`.** The rehearsal's `-win.0` is installed (Task 9 step 4) with the Explorer box ticked, and Ghostty is running with a shell.
     - Run the RC setup: the Restart Manager page appears, Ghostty closes, and Apps & features shows the new version.
     - The verbs and the remembered `explorer` task are still there.
     - A theme file planted in `{app}\share\ghostty\themes` before the upgrade is gone.
     - Repeat with only the tray icon running.
     - Decline "close automatically" → Setup stops with "Ghostty is still running" (no Ignore prompt).
   - **Pin and toasts.** Pin from Start: the jump list shows New Window, New Tab and the profiles. Toasts show under "Ghostty" with the icon, and the running window groups with the pinned icon (AUMID).
   - **Explorer.** "Open Ghostty here" on a folder, a folder background and `C:\` (through "Show more options").
   - **Uninstall while Ghostty runs** (a window, then tray only). The "Close Ghostty to continue" prompt appears, and Cancel leaves everything in place. After closing:
     - gone: the app dir (except user files), the Start entry, the verbs, the Apps & features entry;
     - kept: `%USERPROFILE%\.config\ghostty` and `%LOCALAPPDATA%\ghostty\logs`;
     - a portable copy's verbs (made with `+install-explorer-integration` from an extracted zip before the uninstall) are still there and point to the portable exe.
   - **Portable.** The MOTW zip runs from a path with spaces and from a USB/read-only folder. `+uninstall-explorer-integration --all --only-this-exe` cleans up after it and leaves an installed copy's verbs alone.
   - **ARM64 smoke** (on an ARM64 device; else N/A; not blocking): the arm64 setup installs, Ghostty opens, Git Bash prompt, a split, `tmux.exe -V`, uninstall.

   **After publishing (Task 11 step 6):**
   - The pre-release page shows the assets, and the checksums match the local ones.
   - Download the setup and the zip in a browser and run them: the same SmartScreen behaviour as the MOTW copies.
   - The still-installed `-win.0` rehearsal build with `auto-update = check` shows the update toast for `-win.1`, and the click opens the release page.
10. **Docs.** CHANGELOG M6; SPEC §3, §13, §17, §18 R-M6-*; the two DECISIONS lines (R-M6-11 signed off here); RELEASING.md; `README-windows.txt` in the zip.
11. **Gaps accepted by the owner:** R-M6-9.

Owner sign-off: name, date, tag, PASS/FAIL per line, decision (publish / fix and release `N+1`).

## Self-review

- **Owner scope → tasks:**

  | Owner requirement | Tasks |
  |---|---|
  | x64 + ARM64 portable zip | 4, 8 (both arches), 9 |
  | Inno Setup installer, x64 + ARM64 | 5, 8 |
  | Version resource (FILEVERSION/PRODUCTVERSION, ProductName, icon) in both exes | 1, 2 |
  | `-Dversion-string=<zon>-win.<N>`, tag `win-<zon>-<N>`, pre-release; `Config.zig` and `win-` tags | 1 (R-M6-1), 8 (R-M6-7) |
  | Update check sees the releases | R-M5-9 unchanged; smoke before the upload (R-M6-7); exit checklist 9 (toast from the installed `-win.0`) |
  | **Local** release script: builds both, headless unit filters through the lock, zip + symbols + installers, SHA256, tag rules, printed `git tag`/`git push`/`gh release create … --prerelease --draft` | 8 (R-M6-6/7), 9 |
  | Workflow optional, never on the critical path; free public runners as an overturnable ruling | R-M6-6 (backlog) |
  | ARM64 cross-built locally (gnu); ARM64 tests an owner check, non-blocking | R-M6-6, R-M6-11, 2 (`skip_foreign_checks`), 8 (`-Arm64TestExe`), exit checklist 7 |
  | ISCC found in the owner's per-user path or Program Files, clear failure otherwise | 5 (`build.ps1 -Probe`), 8 (preflight) |
  | `GITHUB_TOKEN` only; signing hook, owner signs manually (gap) | R-M6-8, 4, 5, 8 |
  | Per-user, no admin; Start shortcut with AUMID; per-machine a gap | 5 (R-M6-4) |
  | Opt-in Explorer integration; uninstall reverts with `--all` | 3, 5, 7 |
  | terminfo files; `tmux.exe` next to `ghostty.exe` | 4 (required files), 5 |
  | Uninstaller removes only its own; never the config | 3, 5, 7; exit checklist 9 |
  | Third-party notices in zip + installer before v1.0 (incl. toolchain runtimes, microsoft/terminal) | 13 (R-M6-10) |
  | Bundled ConPTY per arch, `-Dconpty-dir`, next to `ghostty.exe` in zip + installer | R-M6-12; 4, 6, 8 |
  | v1.0 acceptance checklist (E2E all green x64, ARM64 smoke by owner) | 11, § M6 exit checklist |
  | Owner-machine safety (HKCU, network, GUI only via `e2e.ps1`, RAM, privacy) | § Global Constraints, § Owner safety, 4 (privacy), 7 (`/DGhosttyTest`), 8 (RAM gate, groups, serial fallback) |
- **Waves against `Files:`:**

  | Wave | Task | Files |
  |---|---|---|
  | W1 | 1 | `src/build/windows_version.zig`, `src/build/Config.zig`, `update/release.zig` |
  | W1 | 3 | `windows_explorer.zig`, `src/cli/explorer_integration.zig`, `explorer-cli.ps1` |
  | W1 | 4 | `dist/windows/package.ps1`, `dist/windows/lib/Native.psm1`, `README-windows.txt` |
  | W2 | 2 | `dist/windows/{ghostty.rc,tmux.rc,versioninfo.rc}`, `GhosttyExe.zig`, `GhosttyTmuxShim.zig`, `build.zig` (one line) |
  | W2 | 5 | `dist/windows/installer/{ghostty.iss,build.ps1}` |
  | W2 | 6 | `e2e/package-portable.ps1`, `e2e.ps1` |
  | W3 | 7 | `e2e/installer-test.ps1` |
  | W3 | 8 | `release.ps1`, `release-version.ps1`, `release-notes.md`, `docs/windows/RELEASING.md` |
  | W3 | 13 | `THIRD_PARTY_NOTICES.txt`, `third-party-check.ps1`, `package.ps1` |
  | W4 | 10 | CHANGELOG, SPEC, DECISIONS, feature checklist, test README |

  No file is shared inside a wave (Task 8 calls `package.ps1` but does not edit it).

  Cross-wave chains: `package.ps1` 4 → 13 → 9.n; `ghostty.iss` 5 → 9.n; `release.ps1` 8 → 9.n. `src/build/Config.zig` follows the M5 19.n `tic` fix. `installer/build.ps1 -Probe`, used by Task 8, is part of Task 5's file.
- **Names defined once:**

  | Task | Names |
  |---|---|
  | 1 | `windows_version.{TagKind,tagKind,winN,Error,checkVersionString,fileVersion,rcHeader,Exe}` (`release.currentN` delegates) |
  | 2 | `GHOSTTY_*` rc macros (from Task 1's header), `versioninfo.rc` |
  | 3 | `windows_explorer.{PathEql,ownsKeyFor}`, `UninstallOptions.only-this-exe` |
  | 4 | the `package.ps1` parameters; `Native.psm1` (`Find-GitBash`, `Invoke-Native`, `Get-FreeMemoryMB`, `Test-Privacy`) |
  | 5 | the `AppId`s, `AppAumid`, `TrayClass`, the `GhosttyTest`/`Sign` defines, `build.ps1 -Probe` |
  | 8 | the `release.ps1`/`release-version.ps1` parameters, the unit groups, the RAM gate constant, the notes placeholders, `publish.txt` |
  | 13 | the notices section format `== <name> ==`, the exclusion table, the toolchain table |
- **Review Focus → tests:**

  | Focus | Tests |
  |---|---|
  | 1 | Tasks 3, 7 |
  | 2 | owner checklist 9 |
  | 3 | Tasks 1, 4, 8, 9 |
  | 4 | Task 4, G1, Task 9 |
  | 5 | Tasks 8, 9 |
  | 6 | Task 6 |
  | 7 | Task 9, owner checklist |
  | 8 | Task 6 (MOTW), owner checklist 9 |
- **Proportion:** the code blocks are signatures, interfaces and command lines only.
- **Known risks:**
  - ARM64 ships with the MinGW ABI (R-M6-11), with a different C runtime than x64.
  - A full `release.ps1` run is long (three test compiles, two `-Dstrip=false` ReleaseFast builds, optionally the ARM64 test exe) on a 15.5 GB machine. G1's measurement, the RAM gate and the step order keep it to one heavy step at a time.
  - The PDBs carry the checkout path (not the user name).
  - ARM64 is unit-tested only by the owner on a device.

### Owner decisions (2026-10-28, binding; answers to revision 1's open questions)

1. **Third-party notices: yes, before the v1.0 publication.** `THIRD_PARTY_NOTICES.txt` covers the fonts, FreeType, HarfBuzz, the Zig dependencies, the toolchain runtimes, microsoft/terminal and the rest, and ships in the zip and the installer (R-M6-10, Task 13).
2. **Inno Setup is already installed** per-user at `%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe`. `release.ps1` looks there and in Program Files, and fails clearly otherwise (R-M6-6, Tasks 5 and 8).
3. **Per-machine install stays a v1.0 gap** (R-M6-4, R-M6-9).
4. **ARM64 checks do not block a release.** They are recorded owner checks (R-M6-6, exit checklist 7).
5. **Bundled ConPTY ships** (R-M6-12).

Overturnable lead rulings left for the owner:
- R-M6-11: `gnu` ARM64 ABI, signed off in the acceptance;
- R-M6-6: free public runners; no workflow in M6;
- R-M6-3: `-Dstrip=false` with symbols;
- R-M6-1: ignore rather than accept `win-` tags.

Owner option (pre-flight C1): build releases from a neutral checkout path (e.g. `C:\src\ghostty`), so that the PDB source paths do not show the local folder layout.

## Pre-flight dispositions

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | CRITICAL | Published PDBs contain the Windows user name | Applied: `ZIG_GLOBAL_CACHE_DIR=<repo>\zig-out\zig-global` for every release build (Global Constraints, R-M6-3, Task 8); `Test-Privacy` over every staged file, PDB, setup, notes and sums (Task 4, self-test, bites on the Debug PDB); G1 and Task 9 run it on real `-Dstrip=false` PDBs; exit checklist 1; neutral checkout path as an owner option. |
| 2 | IMPORTANT | `zig-out-release\` not git-ignored | Applied: all outputs under `zig-out\` (`release\<version>`, `release\rehearsal-<zon>`, `ver`, `rfs`, `g1`, `tagcheck`, `zig-global`); the `git check-ignore` preflight kept. |
| 3 | IMPORTANT | No `tmux.pdb`; gnu does emit a PDB | Applied: Task 2 sets `.strip = cfg.strip` for the shim and verifies `tmux.pdb`; R-M6-11 says a gnu PDB is expected, `-NoPdbOk` is a fallback; the counts are in one place (R-M6-3: 6 + sums, 5 with `-NoPdbOk`). |
| 4 | IMPORTANT | PowerShell 5.1 pitfalls | Applied: Global Constraints rules (Git Bash by full path, `Invoke-Native` with local `Continue` and exit-code decisions, no non-ASCII literals, `[string]` `-N`, forward-slash zips); `--summary all` for the counts; the Task 8 grep for non-ASCII. |
| 5 | IMPORTANT | Running Ghostty during uninstall/declined upgrade | Applied: `TrayClass` define checked against `tray.zig`; `PrepareToInstall` stop; `InitializeUninstall` Retry/Cancel before `[UninstallRun]`; checklist lines for both; the no-tray second process noted as a known limit. |
| 6 | IMPORTANT | No real `N → N+1` upgrade; stale files | Applied: `[InstallDelete]` for `themes` and `shell-integration`; the owner installs the rehearsal `-win.0` (Task 9 step 4) and upgrades to the RC while Ghostty runs; the extra local RF build for the toast is dropped (the installed `-win.0` shows it). |
| 7 | IMPORTANT | Release run before the push | Applied: Task 11 step 1a; RELEASING step 2 "push first"; R-M6-7 states why. |
| 8 | IMPORTANT | `-Dstrip=false` build unmeasured | Applied: G1 builds it (`RFS`, `-j4`) with a working-set sampler and sets the RAM gate; fallback before the rehearsal; the unwind-table rationale corrected. |
| 9 | IMPORTANT | `--only-this-exe` not tested on its own verbs | Applied: the Task 3 hive test deletes the running exe's own verbs and keeps a foreign one, plus a `\\?\`/8.3 case; Task 7 runs the real flag (no `--dry-run`) with `TEST_IPC=1` + `TEST_HIVE` and asserts the hive afterwards; SKIP if the hive cannot be opened. |
| 10 | IMPORTANT | SmartScreen untestable locally; Smart App Control | Applied: MOTW copies for the owner checks and in `package-portable`; browser download after publishing; SAC recorded; README, notes, R-M6-9 and CHANGELOG say "not supported with Smart App Control on". |
| 11 | IMPORTANT | Notices miss toolchain code | Applied: per-arch toolchain table (Zig std/compiler_rt; libc++/libc++abi/libunwind, MinGW-w64 CRT, winpthreads for arm64-gnu), transitive `zig-pkg` zon files, `--verbose-link` confirmation (Task 13). |
| 12 | MINOR | ARM64 test exe has no build path | Taken: `build.zig` `test_run.skip_foreign_checks = true` (Task 2, touch point, verified). |
| 13 | MINOR | `winver.h` names, no `FILEFLAGSMASK` | Taken: numeric literals with comments and `FILEFLAGSMASK 0x3FL` (R-M6-2). |
| 14 | MINOR | `winN`/`fileVersion` disagree; bare parse error | Taken: `checkVersionString` on the raw `-Dversion-string` before `parse`, no build metadata, never on dev versions; tests use constructed `SemanticVersion` values. |
| 15 | MINOR | `N = 0` passes as a release | Taken: refused without `-Rehearsal`; self-test row; the `-SkipTests` check uses `-N 1`. |
| 16 | MINOR | Deleting the tag frees `N` | Taken: keep the tag, delete only the release (R-M6-7, RELEASING step 8). |
| 17 | MINOR | Printed commands run in no shell | Taken: one PowerShell line per command, quoted absolute paths, a shell header. |
| 18 | MINOR | `[Run]` pins `{app}` as CWD | Taken: `WorkingDir: {%USERPROFILE}`. |
| 19 | MINOR | PS 5.1 zips with `\` | Taken: `UseBackslash` switch off; entry-name check in Task 4. |
| 20 | MINOR | Task 4's failing check cannot fail | Taken: synthetic prefix without `share\terminfo\78`. |
| 21 | MINOR | G1 `package-portable` SKIPs | Taken: G1 sets `GHOSTTY_E2E_PACKAGE`; a SKIP with the lead's input counts as FAIL (also in the test README). |
| 22 | MINOR | Test installer may hit the real dir; `[Code]` not gated | Taken: test `DefaultDirName` under `%TEMP%`, `DisableDirPage`, `VersionInfoDescription` guard, `[Code]` under `#ifndef GhosttyTest`. |
| 23 | MINOR | README `--all` deletes the installed copy's verbs | Taken: `--all --only-this-exe` in the README and checklist. |
| 24 | MINOR | ARM64 ABI recorded inconsistently | Taken in part: Global Constraints, R-M6-6 requirements and a DECISIONS R3 amendment line (Task 10) are consistent now. Declined: relabelling R-M6-11 as an owner decision. The lead recorded it as a ruling forced by the machine; the owner signs it off in the acceptance (exit checklist 10). |
| 25 | MINOR | Over-built | Taken: Task 12 retired to a CHANGELOG backlog line (no `-Ci` mode, no CI scripts); `-KeepPrefix` dropped; budgets against the recorded M5 rows. Declined: removing the signing hook (the owner asked for it) and `-Arm64Abi msvc` (the lead asked for the optional switch); `-Zig`/`-Lock` stay for the serial fallback of MINOR 28. |
| 26 | MINOR | Task 1 creates a real tag | Taken: the check runs in a throwaway `git clone --local` under `zig-out\tagcheck`. |
| 27 | MINOR | v1.0 gate partly in the checklist | Taken: `vt-smoke.ps1` against the RC (Task 11, checklist 3); "upstream tests on Windows = group 3" stated in the acceptance record. |
| 28 | MINOR | Repo visibility; dependence on agent tooling | Taken: RELEASING step 1 visibility check; serial mode without the test-lock. |
| 29 | MINOR | Commit type for Task 13 | Taken: `build(windows): …`. |
| 30 | MINOR | Tag pushes trigger upstream workflows | Taken: disabling them is a one-time RELEASING step. |
