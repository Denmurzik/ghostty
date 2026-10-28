# M6 — Release (version resource, portable zip, Inno Setup installer, local release script, pre-release, v1.0 gate): Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the Windows port ships, for x64 and ARM64:
- `ghostty.exe` and `tmux.exe` with a Windows version resource (FILEVERSION/PRODUCTVERSION, ProductName, icon);
- a portable zip;
- a per-user Inno Setup installer (Start-menu shortcut with the app's AUMID, opt-in "Open Ghostty here", terminfo, `tmux.exe` next to `ghostty.exe`, an uninstaller that removes only what it installed);
- a **local** release script (`dist/windows/release.ps1`) that, on the owner's machine:
  - builds x64 and ARM64 ReleaseFast with `-Dversion-string`;
  - runs the headless unit filters through the test-lock;
  - packages the zips and installers and writes `SHA256SUMS.txt`;
  - **prints** (never runs) the `git tag`/`git push`/`gh release create … --prerelease --draft` commands for the owner;
- `THIRD_PARTY_NOTICES.txt` in the zip and the install dir (owner decision 1);
- the v1.0 acceptance checklist, signed by the owner.

A GitHub Actions workflow is optional, manual-only and never needed for a release (R-M6-6, Task 12).

Exit (SPEC §17 M6): the owner signs the acceptance checklist (§ M6 exit checklist).

**Revision 3 (plan-m6, 2026-10-28):** owner update (binding): the GitHub Actions minutes on the owner's account are exhausted, so the release path is local and CI is off the critical path (R-M6-6, R-M6-7).
- The CI tasks of revision 1 became the local release script (Task 8) and a local rehearsal (Task 9).
- An optional `workflow_dispatch`-only `windows-ci.yml` is Task 12; nothing depends on it.
- ARM64 unit tests became an owner check.
- The printed `gh release create` makes a draft pre-release.
- The owner's answers to the open questions are recorded under "Owner decisions"; the third-party notices are a new Task 13.

**Architecture:**
- **Build.** A std-only helper `src/build/windows_version.zig` owns the version rules: `win-` tag handling, `-win.<N>` parsing, FILEVERSION and the generated `.rc` header. `Config.zig`, `GhosttyExe.zig` and `GhosttyTmuxShim.zig` call it. Its tests run in the main test exe.
- **Packaging.** PowerShell scripts under `dist/windows/`:
  - `package.ps1` stages, verifies, zips, calls ISCC and optionally signs one arch;
  - `release.ps1` orchestrates a whole release (preflight, tests, two builds, two packages, sums, notes, printed commands);
  - `release-version.ps1` is the pure tag/version validation.
- **Installer.** One Inno Setup script for both arches (`/DArch=`). A `/DGhosttyTest` variant has no registry, no shortcuts and no Restart Manager, so a sandboxed e2e can install and uninstall it on the owner's machine.
- **Publishing** is the owner's: the script prints the commands; it never pushes, tags or calls `gh`.

**Tech Stack:** Zig 0.17.0 (MSVC ABI, Zig's resource compiler), PowerShell 5.1, Inno Setup 6.4+ (`ISCC.exe`, arm64 support), Git for Windows (`tic.exe`, `bash.exe` for the test-lock), `gh` CLI (run by the owner only). Optional: GitHub Actions (`windows-2025`, `windows-11-arm`).

**Spec:** `docs/windows/SPEC.md` (with `docs/windows/DECISIONS.md` the authority):
- §1 (non-goals: code signing, MSIX), §2 (`dist/windows/` layout), §3 (release recipe flags), §13 (packaging; as amended by M5 Task 20), §14 (RAM), §16 R15/R16, §17 M6, §18.3 (AUMID toasts).
- DECISIONS "Release" (zip + Inno "built by GitHub Actions on tag", amended by R-M6-6; no certificate, SmartScreen accepted) and the v1.0 gate (feature checklist closed, upstream + win32 tests, vttest-style checks, RAM, Claude Code tmux run, owner smoke of a pre-release).
- M5 hand-over: R-M5-5 (Explorer keys, `--all`, installer shortcut AUMID), R-M5-9/9a (update check, `<zon>-win.<N>`, `win-<zon>-<N>`, pre-releases, compare `N`), R-M5-7 (compiled terminfo, `-Dtic`).

Other inputs:
- Owner decisions for M6 (2026-10-28, binding; summarised in the Goal and Rulings), including the revision 2 update.
- The owner's global rule: check free RAM before heavy test runs, or run them in smaller parts.
- Memory rules: speed over ceremony; style follows macOS (not relevant here except the icon).
- Format and conventions: `docs/windows/plans/M5-windows-extras.md`, `docs/windows/plans/M5-preflight-review.md`.

**Starts** when M5 is accepted (Task 20) **and** the M5 19.n batch that touches `src/build/Config.zig` (`tic`) has landed. Tasks 3, 4 and 5 touch no M5-owned file in flight and may start once M5 W8 has started. Task numbers are identities, not order: the wave table is the execution order.

## Global Constraints

Carried from M1–M5 (every task implicitly includes these):

- Zig 0.17.0 at `C:\tools\zig-x86_64-windows-0.17.0\zig.exe` (full path). Shell: Git Bash. Target ABI MSVC. Minimum OS Windows 11 22H2 (Windows 10 best effort).
- Core edits only in "M6 core touch points". A cause found outside them: the implementer stops with evidence; the lead schedules an `n.1` task.
- Commits: no `Co-Authored-By` or similar trailers. Never `python -` (nor `python3 -` with a heredoc).
- Worktree bootstrap: `cmd //c mklink /J "<worktree>\zig-pkg" "C:\D\den4ik\Ghostty\zig-pkg"`. A worktree's first (cold) build runs with `run_in_background` under `timeout 1500` through the test-lock.
- **Privacy:** no Windows user name in any committed file, report or release note. Paths are written as `%USERPROFILE%`, `%LOCALAPPDATA%`, `%APPDATA%`. The release notes carry counts, never local paths.
- **PowerShell scripts** target Windows PowerShell 5.1 (`powershell -NoProfile`), `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, no modules beyond the inbox ones. Each new script must parse:
  ```
  powershell -NoProfile -Command "[ScriptBlock]::Create((Get-Content -Raw <file>)) | Out-Null"
  ```

**Owner safety (M2–M5 rules, extended for M6).** None of these needs a per-run approval, because none touches owner state.

- **Harness.** e2e scenarios run only through `test/windows/e2e.ps1`:
  - shared desktop lock, a per-scenario `class`, the sandbox env (`New-E2eSandbox`: `XDG_CONFIG_HOME`, `APPDATA`, `LOCALAPPDATA`, `USERPROFILE` under the sandbox);
  - every Ghostty a scenario starts gets `--class=<scenario class>`, is registered with `Register-OwnGhostty` and stopped in `finally`;
  - evidence images only through the guarded capture helpers.
- **Registry.** No test, scenario, implementer run or `release.ps1` run writes the real `HKCU`/`HKLM`.
  - The Explorer CLI runs only with `--dry-run` or with `GHOSTTY_WIN32_TEST_HIVE=<file>` (M5 rule).
  - The **real** installer and uninstaller never run in a test, an implementer run or `release.ps1`. They run only in the owner's manual checks, or on a CI runner if the optional Task 12 is ever used (`installer-smoke.ps1` refuses unless `GITHUB_ACTIONS=true`).
  - On the owner's machine only the `/DGhosttyTest` installer runs (R-M6-4). It has:
    - no uninstall key, no shortcuts, no Explorer task;
    - no Restart Manager session, so none of RM's volatile `HKCU\Software\Microsoft\RestartManager` keys;
    - an uninstaller that calls the Explorer CLI with `--dry-run`.

    The scenario snapshots the relevant `HKCU` keys read-only before and after, and asserts no change.
- **Files.** Packaging and `release.ps1` write only under their `-OutDir` (default `zig-out-release\`, git-ignored by the existing `zig-out*` pattern; Task 8 checks). Nothing writes `%LOCALAPPDATA%\Programs`, the Start menu, the desktop or `%USERPROFILE%\.config\ghostty` on the owner's machine, except the owner's manual checks.
- **Network.** No test reaches the internet (M5 ruling C3 holds). `release.ps1` makes no network call: it reads only local git refs and tells the owner to `git fetch --tags origin` first.
- **Outward-facing actions** (push, tag push, `gh release …`, publishing, a workflow dispatch) are the owner's. `release.ps1` prints them; implementers and the lead never run them without the owner's explicit go for that action.
- **RAM.** Every heavy step (test compile, ReleaseFast build) runs through the test-lock (≥ 2 GB free per slot). `release.ps1` also checks free physical memory ≥ 3 GB before each heavy step, and runs the unit filters in three smaller groups (owner's global rule).

Speed rules (owner 2026-10-26/28; unchanged):

- Builds and tests use `-j6` through the test-lock (3 slots). Bash timeout 600000. Prefer a focused `-Dtest-filter`; never the full suite locally.
- A ReleaseFast build with a different `-Dversion-string` rebuilds the whole exe: at most one such build per task (outside `release.ps1`), into its own `--prefix`.
- Implementers run unit tests, `LOCK ZIG build -j6`, script parse checks and the pure `-SelfTest`/`-DryRun` modes. The lead runs the e2e batches (G1, Task 11) and the release rehearsal (Task 9).
- Up to 3 writers in flight; a task starts as soon as its dependencies have landed and its files do not collide.
- Every task: unit tests or a self-test, plus at most one e2e scenario.
- **Review tier** (stated per task): `light` = one batched sonnet review per wave; `opus` = per-task review for what an uninstaller deletes, owner safety, or release integrity.

Command abbreviations (expand literally; shell state does not persist):
- `LOCK` = `bash "%USERPROFILE%/.claude/mods/teamlead/skills/teamlead/scripts/test-lock" --`
- `ZIG` = `"C:/tools/zig-x86_64-windows-0.17.0/zig.exe"`
- `PS` = `powershell -NoProfile -ExecutionPolicy Bypass -File`
- `E2E` = `PS test/windows/e2e.ps1` (lead only, after the build it tests)
- `RF` = `LOCK ZIG build -j6 -Doptimize=ReleaseFast -Demit-themes=true -Demit-terminfo=true -Dtarget=x86_64-windows-msvc --prefix zig-out-rf` (the local release recipe; add `-Dversion-string=…` where a task says so)
- Test name prefixes: `windows version: ` (new, `src/build/windows_version.zig`), `windows explorer: `, `explorer cli: `, `win32 update: ` (existing).

### M6 core touch points (complete list)

| File | Change | Task |
|---|---|---|
| `src/build/windows_version.zig` | new, std only: tag kind, `-win.<N>`, FILEVERSION, rc header | 1 |
| `src/build/Config.zig` | the git tag check ignores `win-` tags (R-M6-1) | 1 |
| `src/apprt/win32/update/release.zig` | `currentN` delegates to `windows_version.winN`; test block references the new file | 1 |
| `src/build/GhosttyExe.zig` | generated version header + include path for `ghostty.rc` | 2 |
| `src/build/GhosttyTmuxShim.zig` | `tmux.rc` with the same generated header | 2 |
| `dist/windows/ghostty.rc` | `#pragma code_page(65001)`; the commented VERSIONINFO block replaced by `#include "versioninfo.rc"` | 2 |
| `src/os/windows_explorer.zig` | `ownsKeyFor` (owner = this exe) | 3 |
| `src/cli/explorer_integration.zig` | `+uninstall-explorer-integration --only-this-exe` | 3 |

Not touch points:
- `src/apprt/win32/**` (other than `release.zig`), `src/termio/**`, `src/config/Config.zig`.
- `build.zig`, `build.zig.zon`: the zon version stays upstream's (R-M5-9a).
- The upstream workflows in `.github/workflows/` (R-M6-6).

### RAM and latency budget

Same binary as M5 except the version resource and `-Dstrip=false` (R-M6-3). Measured on the release candidate's x64 exe from the `release.ps1` zip, with `test/windows/measure-ram.ps1` and `input-latency`, against the M5 acceptance rows re-measured the same day.

| Item | Budget | Measured by |
|---|---|---|
| RC `ghostty.exe`, default config, 1 window 1 surface, 30 s after start | ≤ M5 acceptance row + 1 MB | Task 11 |
| RC `tmux.exe` peak private (`display-message`) | ≤ 5 MB (SPEC §14) | Task 11 |
| Key echo, Ghostty-owned p95 | within +0.5 ms of M5 | Task 11 |
| Startup to first frame | within +10 ms of M5 | Task 11 |
| `release.ps1` full run: peak of the heaviest step | the test-lock's slot rule; no OOM; record the wall time | Task 9 |

Over budget: DONE_WITH_CONCERNS with numbers. If `-Dstrip=false` is the cause, R-M6-3's fallback applies (strip, ship no symbols).

## Review Focus

1. **The uninstaller removes exactly what the installer put there.**
   - Removed: installed files, the Start-menu (and optional desktop) shortcut, the uninstall entry, the Explorer verbs that name **this** `ghostty.exe`, the AUMID registration and the toast icon (`--all`).
   - Kept: `%USERPROFILE%\.config\ghostty\**`, `%LOCALAPPDATA%\ghostty\**` except the toast icon (logs, crash dumps, `update.json`), files the user added under the install dir (and so the dir itself), the verbs of another (portable) `ghostty.exe`.
   - Tests: Task 3 `windows explorer: only-this-exe …`, `explorer cli: --only-this-exe keeps a foreign verb`; Task 7 `installer-test.ps1`; owner checklist (the real installer).
2. **Install, upgrade or uninstall while Ghostty runs.** Cases: a window with shells; tray only (no window); a Claude Code team using `tmux.exe` from the install dir.
   - Expected:
     - the Restart Manager page lists Ghostty, and "close automatically" ends it through `WM_QUERYENDSESSION`/`WM_ENDSESSION` (the tray window already answers both);
     - no half-replaced install dir (Inno's retry/abort on a locked file);
     - the upgrade keeps the Explorer verbs and the remembered tasks.
   - Tests: owner checklist (the only place the real installer meets real processes).
3. **One version everywhere.** Tag `win-<zon>-<N>` ↔ `build.zig.zon` version ↔ `-Dversion-string=<zon>-win.<N>` ↔ `+version` ↔ VersionInfo (FileVersion `major.minor.patch.N`) ↔ the update check's `N` ↔ the printed `git tag` (pinned to the built commit's SHA).
   - A malformed `N` never produces artifacts; `N` only grows and is never reused; a local build at a tagged commit neither panics nor counts as a release.
   - The printed tag names the commit that was built, even if the owner checks out something else before running it.
   - Tests: Task 1 `windows version: …`; Task 8 `release-version.ps1 -SelfTest`, `release.ps1 -DryRun`; Task 4 package verification; Task 9 rehearsal.
4. **The release script on a low-RAM machine.**
   - Heavy steps run one at a time through the test-lock. The unit filters run in three groups.
   - A failed step stops the run with the step name and leaves no half-written `SHA256SUMS.txt`.
   - Re-running with the same `N` refuses an existing output dir unless `-Force`.
   - A dirty tree or a commit outside local `origin/windows` refuses (except `-Rehearsal`).
   - Tests: Task 8 `-DryRun` and `-SelfTest`; Task 9 rehearsal (wall time and peak recorded).
5. **The portable zip from odd places.** Paths with spaces, Cyrillic, over 260 characters, a read-only folder; a zip whose `share` folder was moved.
   - Expected:
     - resources found (`share\terminfo\ghostty.terminfo` sentinel);
     - `TERM` falls back to `xterm-256color` when the compiled entry is missing (R-M5-7);
     - `tmux.exe` first on `PATH` inside sessions;
     - nothing written next to the exe.
   - Tests: Task 6 `package-portable.ps1` (space + Cyrillic dir); owner checklist (USB/read-only).
6. **Release binaries run on every target machine.**
   - Always an explicit `-Dtarget` (`x86_64-windows-msvc`, `aarch64-windows-gnu` by default, R-M6-11): CPU baseline, never the build machine's native features.
   - ARM64 with the MinGW ABI: does the gnu build behave like the M5 msvc code paths (COM vtables, `callconv(.winapi)`, `@alignCast` sites fixed in M3, the dump writer)? Only `-Arm64Abi msvc` needs the VS ARM64 libraries; the preflight then names the missing component.
   - The ARM64 unit tests cannot run on this machine; they are an owner check (R-M6-6).
   - Tests: Task 9 (both arches build and package; `+version` of x64 only); owner ARM64 test exe and smoke (non-blocking).

## Rulings (plan-m6, 2026-10-28; lead/owner may overturn; recorded in SPEC §18 by Task 10)

The owner's M6 decisions (binding, not re-asked):
- deliverables for x64 and ARM64 (zip, Inno installer, version resource in both exes);
- the version scheme of R-M5-9a;
- releases as GitHub pre-releases; no secret beyond `GITHUB_TOKEN`;
- signing is manual;
- per-user installer with the AUMID shortcut, opt-in Explorer integration, terminfo, `tmux.exe`; uninstall reverts with `--all` and never touches the config;
- the v1.0 checklist signed by the owner;
- **(revision 3)** the release path is local, and a workflow, if any, is `workflow_dispatch`-only and not required;
- **(revision 3, answers to the open questions; see § Owner decisions)** a third-party notices file before v1.0; Inno Setup is installed per-user; per-machine install stays a gap; ARM64 checks do not block a release.

- **R-M6-1 `src/build/Config.zig` ignores `win-` tags.**
  - Today a commit whose exact tag is not `tip` and not `v<zon>` panics the build (`tagged releases must be in vX.Y.Z format`) unless `-Dversion-string` is given.
  - New rule: a tag starting with `win-` is treated like `tip`. The build falls through to the dev version `<zon-major.minor.patch>-<branch>+<hash>`.
  - The release version comes **only** from `-Dversion-string=<zon>-win.<N>`, which `release.ps1` passes after validating `N` (R-M6-7).
  - Accepting the tag (deriving the version from it) was rejected: two sources of truth, and a local build at a release commit would silently turn on the update check.
  - Upstream `vX.Y.Z` behaviour is unchanged.
  - On a Windows target, a version string containing `-win.` must end in a canonical `N` (digits, no leading zero) with `N ≤ 65535`. Anything else is a build error naming the value. 65535 is the FILEVERSION field limit.
  - Cost if wrong: one `switch` arm.
- **R-M6-2 Version resource** (both exes; one VERSIONINFO block in `dist/windows/versioninfo.rc`, the per-exe values in a header the build generates):
  - `FILEVERSION`/`PRODUCTVERSION` = `major,minor,patch,N` (`N = 0` without `-win.<N>`).
  - `FILEFLAGS` = `VS_FF_PRERELEASE` when the semver has a pre-release part, plus `VS_FF_DEBUG` in Debug.
  - `FILEOS VOS_NT_WINDOWS32`, `FILETYPE VFT_APP`.
  - Strings (`040904b0`):
    - `ProductName` = `Ghostty — Unofficial Windows port` (SPEC §13; UTF-8 source, `#pragma code_page(65001)`);
    - `ProductVersion` = `FileVersion` = the full version string;
    - `FileDescription` = `Ghostty` / `Ghostty tmux shim` (Task Manager shows this);
    - `OriginalFilename`, `InternalName` = `ghostty.exe` / `tmux.exe`;
    - `LegalCopyright` = `Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors` (`LICENSE`);
    - no `CompanyName`.
  - Icon: `ghostty.ico` in both (`tmux.rc` is new). It adds no imports, so `tmux.exe` still imports only kernel32/ntdll.
- **R-M6-3 Artifacts and layout.**
  - Names: `ghostty-<version>-windows-<arch>.zip`, `ghostty-<version>-windows-<arch>-setup.exe`, `ghostty-<version>-windows-<arch>-symbols.zip`, and one `SHA256SUMS.txt` for all assets. `<arch>` is `x64` or `arm64`; `<version>` is the `-Dversion-string`.
  - The zip has one top folder `ghostty-<version>-windows-<arch>\`, so that extraction never spills files. Inside:
    - `ghostty.exe`, `tmux.exe`, `LICENSE`, `THIRD_PARTY_NOTICES.txt` (R-M6-10), `README-windows.txt`;
    - `share\` with the existing subfolders among `ghostty`, `terminfo`, `bash-completion`, `fish`, `zsh`, `vim`, `nvim`, `bat`, `man` (an allowlist; anything else the prefix has, e.g. Linux desktop files, is left out);
    - no `.pdb`.
  - Required, else packaging fails:
    - `share\ghostty\themes` (non-empty) and `share\ghostty\shell-integration`;
    - `share\terminfo\ghostty.terminfo` (the resources sentinel of `resourcesdir.zig`);
    - `share\terminfo\78\xterm-ghostty` (compiled, R-M5-7). Only a non-release local run may waive it with `-AllowNoTic`; `release.ps1` never does.
  - **Release builds use** `-Doptimize=ReleaseFast -Demit-themes=true -Demit-terminfo=true -Dstrip=false -Dtic=<Git's tic.exe> -Dversion-string=<v>`, with `-Dtarget=x86_64-windows-msvc` or `-Dtarget=aarch64-windows-gnu` (`msvc` optional, R-M6-11).
    - `-Dstrip=false` yields the PDBs for the M5 crash dumps, shipped only in `-symbols.zip`. It also keeps frame pointers and unwind tables, which help the dumps.
    - Cost if wrong (the Task 11 RAM/latency rows): drop to the default strip and ship no symbols.
- **R-M6-4 Installer** (`dist/windows/installer/ghostty.iss`).
  - **Privileges and arch.**
    - Per-user only: `PrivilegesRequired=lowest`, no override dialog. An all-users install is a v1.0 gap.
    - `DefaultDirName={autopf}\Ghostty` (`%LOCALAPPDATA%\Programs\Ghostty`); `DisableProgramGroupPage=yes`.
    - `AppId={{37134A5A-16BD-4127-9CC0-134E0CF32BA5}`, fixed forever. The test variant uses `{{B6635077-20E7-4DDF-A062-7D9F8711ADF2}`.
    - x64: `ArchitecturesAllowed=x64compatible`, `ArchitecturesInstallIn64BitMode=x64compatible`. arm64: both `arm64`.
    - `MinVersion=10.0.17763` (the ConPTY floor; Windows 10 is best effort per DECISIONS).
  - **Files:** the zip's content (same stage, same allowlist); `UninstallDisplayIcon={app}\ghostty.exe`; `SetupIconFile=..\ghostty.ico`; `WizardStyle=modern`; English only; no license page (MIT, the file is installed).
  - **Shortcuts.**
    - `[Icons]` `{autoprograms}\Ghostty` → `{app}\ghostty.exe`, `WorkingDir: {%USERPROFILE}`, `AppUserModelID: "com.mitchellh.ghostty.windows-unofficial"`. This is the release `windows_explorer.aumid`; `package.ps1` checks that they match.
    - Optional desktop shortcut (task `desktopicon`, unchecked), the same.
  - **Explorer task** `explorer` (unchecked, label `Add "Open Ghostty here" to the Explorer folder menu`).
    - `[Code]` `CurStepChanged(ssPostInstall)` runs `{app}\ghostty.exe +install-explorer-integration` hidden and waits.
    - A non-zero exit code shows a suppressible warning and is logged; the install still succeeds.
    - Unticking it on an upgrade does not remove existing verbs (the uninstaller does).
  - **Uninstall.**
    - `[UninstallRun]` always runs `{app}\ghostty.exe +uninstall-explorer-integration --all --only-this-exe` (hidden, waits, `RunOnceId: "ExplorerRevert"`), whether or not the task was ticked. `--all` also removes the AUMID key and toast icon the app creates at runtime (SPEC §13). `--only-this-exe` (R-M6-5) keeps a portable copy's verbs.
    - No `[UninstallDelete]`: Inno removes exactly the files it logged. User-added files keep the dir.
  - **Running Ghostty:** `CloseApplications=yes`, `RestartApplications=no`. No PATH change (SPEC §13). Postinstall "Launch Ghostty" (`postinstall nowait skipifsilent`).
  - **`/DGhosttyTest`** (Task 7 only): `CreateUninstallRegKey=no`, `CloseApplications=no`, no `[Icons]`, no `[Tasks]`, `[UninstallRun]` gets `--dry-run`, and the output name ends `-setup-test.exe`.
- **R-M6-5 `+uninstall-explorer-integration --only-this-exe`.**
  - With the flag, a verb key counts as ours only if its `command\(default)` names this very exe. Full paths are compared with `CompareStringOrdinal(…, TRUE)` on UTF-16 (the file system's rule).
  - Without the flag, the R-M5-5 rule (any `ghostty.exe`) is unchanged.
  - `--all`'s AUMID and toast-icon removal is not affected.
  - `--dry-run` with the flag prints `delete <key> if its command names <exe>`.
- **R-M6-6 Local release path; GitHub Actions optional and manual-only** (owner update 2026-10-28; amends DECISIONS "built by GitHub Actions on tag" and SPEC §13's CI line).
  - **A release needs only the owner's machine:**
    - Zig 0.17.0;
    - VS Build Tools with the x64 **and ARM64** MSVC libraries;
    - Git for Windows (`tic.exe`, `bash.exe`);
    - Inno Setup 6.4+, already installed per-user (owner decision 2). Found at `%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe`, else `%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe` or `%ProgramFiles%\Inno Setup 6\ISCC.exe`. `$env:ISCC` overrides. None → the release stops with `ISCC.exe not found (looked in: <the three paths>); install Inno Setup 6 or set ISCC`;
    - `gh` logged in (used only by the owner, by hand).
  - **Unit tests** in `release.ps1`: three groups, each one test-exe compile through the test-lock, then `test-tmux-shim`. These are the M1–M5 exit filters, all headless:
    1. `-Dtest-filter="win32 "`;
    2. `-Dtest-filter="windows " -Dtest-filter="tmux shim " -Dtest-filter="Exec: w" -Dtest-filter="d3d11 "`;
    3. `-Dtest-filter="terminal" -Dtest-filter="config" -Dtest-filter="input" -Dtest-filter="font"`.

    The groups are defined once, in `release.ps1`. Any failure stops the release.
  - **ARM64** (owner decision 4: ARM64 checks never block a release):
    - Cross-built locally with `aarch64-windows-gnu` by default; `-Arm64Abi msvc` is the optional switch (R-M6-11).
    - ARM64 unit tests are an **owner check**, because there is no ARM64 runner.
      - With `-Arm64TestExe`, `release.ps1` builds one ARM64 test exe (`-Demit-test-exe`, groups 1+2 filters, `-Dtarget=aarch64-windows-<abi>`) without running it.
      - It zips that exe as `ghostty-<v>-windows-arm64-tests.zip`, local only and never published.
      - The owner runs it on an ARM64 device. Exit 0 = PASS; a failure is recorded, not blocking.
      - Task 8's implementer confirms the build path that installs the foreign test exe without trying to run it. If none exists, the owner check is the ARM64 smoke alone and the report says so.
  - **Optional workflow (Task 12, may be skipped; nothing depends on it).**
    - One file, `.github/workflows/windows-ci.yml`, with `on: workflow_dispatch` **only** (no push, tag, schedule or PR triggers) and `permissions: contents: read` (it can never create a release).
    - It runs `release.ps1 -Ci` on `windows-2025` plus the ARM64 unit groups on `windows-11-arm` (`continue-on-error`), and uploads the artifacts to the run.
    - Ruling: standard GitHub-hosted runners are normally free for **public** repositories, so the exhausted minutes may not apply to this public fork. The owner may confirm this and later re-enable push triggers (a one-line change). The release path stays local either way.
  - Upstream workflow files are not edited (clean merges). Their jobs ask for `namespace-profile-*` runners the fork does not have; the owner may disable them in the fork's Actions settings so that they stop queueing.
- **R-M6-7 Release.**
  - **Tag** `win-<zon>-<N>`, annotated, created and pushed by the owner from the command `release.ps1` prints. The tag is pinned to the built commit's SHA. `N` starts at **1**, is fork-wide and never reused, even for a deleted release.
  - **Validation** (`dist/windows/release-version.ps1`, R-M5-9a rules) refuses when:
    - `N` is not canonical (`0|[1-9][0-9]*`), or `N > 65535`;
    - `<zon>` is not `build.zig.zon`'s `.version`;
    - `N` is not greater than every local `win-*` tag's `N` (the script tells the owner to `git fetch --tags origin` first);
    - the tree is dirty;
    - HEAD is not an ancestor of (or equal to) the local `origin/windows`.

    `-Rehearsal` builds with `N = 0`, skips the last three checks, marks every printed command `# REHEARSAL — do not run`, and writes to `zig-out-release\rehearsal-<zon>\`.
  - **Printed commands** (to stdout and `<OutDir>\publish.txt`):
    ```
    git tag -a win-<zon>-<N> <sha> -m "Ghostty <zon>-win.<N>"
    git push origin win-<zon>-<N>
    gh release create win-<zon>-<N> --repo Denmurzik/ghostty --prerelease --draft --verify-tag \
      --title "Ghostty <zon>-win.<N> (unofficial Windows port)" --notes-file <OutDir>\release-notes.md \
      <the 6 artifacts> <OutDir>\SHA256SUMS.txt
    # after checking the draft page:
    gh release edit win-<zon>-<N> --repo Denmurzik/ghostty --draft=false
    ```
  - **Order:** the owner smokes the **local** artifacts first (exit checklist 8), then runs the commands, checks the draft page and publishes. The update check ignores drafts and reads pre-releases (R-M5-9), so users see the release only after the last command.
  - **Notes** from `dist/windows/release-notes.md`:
    - the version, and "Windows port v1.0" when `-V1` is given;
    - the unsigned/SmartScreen note, install and portable notes;
    - the unit-test counts per group, and "ARM64: built; unit tests are an owner check (no ARM64 runner)" with the owner's result if given;
    - the checksums.
  - `release_channel` stays `tip` for `-win.<N>` builds (semver pre-release). At this plan's base it only shows in `+version` on Windows. The M5 19.n batch 2 "update channel" item may give it a meaning; Task 1's implementer re-checks that the updater still looks only at `N` (R-M5-9a).
- **R-M6-8 Signing hook, no certificate (gap).**
  - Artifacts are unsigned by default (DECISIONS: SmartScreen warning accepted).
  - `release.ps1 -SignCommand '<command with {file}>'` passes through to `package.ps1`. That signs `ghostty.exe` and `tmux.exe` in the stage before zipping. It also gives ISCC `/DSign /Ssigntool=<command with $f>`, so `setup.exe` and the uninstaller (`SignedUninstaller=yes`) are signed.
  - The PDBs still match: signing does not change the code.
  - `package.ps1 -FromZip` re-signs an existing zip without a build, for a release that was already published unsigned. The owner then uses `gh release upload --clobber` and a regenerated `SHA256SUMS.txt`.
- **R-M6-9 What M6 does not do** (v1.0 gaps, in the CHANGELOG):
  - all-users (per-machine) install (owner decision 3); a PATH entry for external tmux (documented instead);
  - MSIX and the Windows 11 top-level context menu;
  - a certificate; automated ARM64 unit tests (an owner check, non-blocking; owner decision 4);
  - winget/scoop manifests;
  - jump-list removal on uninstall (Explorer drops it when the shortcut is gone; the CLI has no COM, R-M5-5).
- **R-M6-10 Third-party notices** (owner decision 1).
  - `dist/windows/THIRD_PARTY_NOTICES.txt` ships at the zip root and in the install dir.
  - It lists every component compiled, linked or embedded into the Windows `ghostty.exe`/`tmux.exe`, or shipped under `share` (e.g. the iTerm2 colour schemes), with its licence name and full licence text: fonts (JetBrains Mono, Nerd Fonts symbols), FreeType, HarfBuzz, zlib, libpng, oniguruma, simdutf, highway, wuffs, glslang, SPIRV-Cross, Dear ImGui, the Zig packages and the vendored `pkg/*` C sources.
  - Packaging fails when a `build.zig.zon` dependency is neither in the file nor in the check's exclusion list. Each exclusion carries a reason, e.g. `gtk4_layer_shell: Linux only`.
- **R-M6-11 ARM64 release ABI is `aarch64-windows-gnu` by default** (lead, 2026-10-28; owner may overturn). Amends DECISIONS R3 (MSVC) for the ARM64 release artifacts only.
  - **Why:** the owner's VS 18 Build Tools have only the x86/x64 MSVC tools. Adding "MSVC ARM64 build tools" needs admin. `aarch64-windows-gnu` needs nothing extra, because Zig ships the MinGW-w64 libraries. M3–M5 proved it: the cross-build passed in each acceptance (M3 after `117aa103b`).
  - **x64 stays `x86_64-windows-msvc`.**
  - **`release.ps1 -Arm64Abi gnu|msvc`**, default `gnu`.
    - `msvc` is the optional switch, for after the owner has added the VS component. Only then does the preflight check `vswhere -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64` and name the missing component.
    - The chosen ABI is printed in the notes (`ARM64 build: aarch64-windows-gnu`) and in `+version` (Zig target).
  - **Consequences:**
    - **Symbols.** A `-gnu` build may emit no `.pdb`. When `prefix-arm64\bin\*.pdb` is missing under `gnu`, the arm64 `-symbols.zip` is left out with one notes line, and ARM64 crash dumps cannot be symbolised in WinDbg (gap). x64 keeps its PDBs (R-M6-3).
    - **C runtime.** MinGW instead of the VC runtime for the C dependencies. `tmux.exe` has no libc (`link_libc = false`) and is unaffected.
    - **Checks.** The ARM64 test exe (`-Arm64TestExe`) uses the same ABI as the release, so the owner's device run tests what ships. The VersionInfo and import checks of `package.ps1` apply unchanged; the `dumpbin` import list is still readable.
  - **Cost if wrong:** add the VS component (admin, one time) and pass `-Arm64Abi msvc`.

## Waves (parallelism)

≤ 3 tasks per wave; file sets inside a wave are strictly disjoint.

| Wave | Tasks | Depends on |
|---|---|---|
| W1 | 1 version helper + `win-` tags · 3 `--only-this-exe` · 4 `package.ps1` + `README-windows.txt` | M5 accepted, M5 19.n `Config.zig` landed (1); — (3, 4) |
| W2 | 2 version resources · 5 Inno script + `installer/build.ps1` · 6 `package-portable.ps1` scenario | 1 (2); 3+4 (5); 4 (6) |
| G1 | **Lead batch:** `RF -Dversion-string=<zon>-win.0`, `PS dist/windows/package.ps1 -Prefix zig-out-rf …`, `E2E -Only explorer-cli,package-portable,dpi-sim`; ISCC present → also the test installer | 2, 3, 5, 6 |
| W3 | 7 `installer-test.ps1` scenario · 8 `release.ps1`, `release-version.ps1`, notes template, `RELEASING.md` · 13 `THIRD_PARTY_NOTICES.txt` + check | 5 (7); 2+4+5 (8); 4 (13) |
| G2 | **Task 9 (lead):** `release.ps1 -Rehearsal` on the owner's machine, `E2E -Only package-portable,installer-test` on its output, 9.n fixes (no CI run is a gate) | 7, 8, 13 |
| W4 | 10 docs: CHANGELOG, SPEC, DECISIONS amendment line, feature checklist, test README (alone) | 9.* |
| W5 | 11 release candidate, v1.0 acceptance, owner sign-off (lead + owner) | 10 |
| opt | 12 `workflow_dispatch`-only `windows-ci.yml` (any time after 8; no task or release depends on it) | 8 |

Hot-file chains (every file touched by more than one task):
- `dist/windows/package.ps1`: 4 → 13 → 9.n.
- `dist/windows/installer/ghostty.iss`: 5 → 9.n.
- `dist/windows/release.ps1`: 8 → 9.n → 12 (`-Ci` mode).
- `test/windows/e2e.ps1` (`ValidateSet` += `M6`): 6 only.
- `test/windows/e2e/explorer-cli.ps1`: 3 only.
- `docs/windows/{SPEC.md, CHANGELOG.md, feature-checklist.md, DECISIONS.md}`, `test/windows/README.md`: 10 (+ Task 11 acceptance lines).

Interfaces fixed by this plan (so W2/W3 tasks run in parallel):
- `package.ps1` (Task 4):
  ```
  package.ps1 (-Prefix <dir with bin\ and share\> | -FromZip <zip>) -Version <v> -Arch x64|arm64 -OutDir <dir>
              [-Installer] [-Test] [-Symbols] [-NoPdbOk] [-SignCommand '<cmd {file}>'] [-AllowNoTic]
  ```
  - Writes `<OutDir>\ghostty-<v>-windows-<arch>.zip`; with `-Symbols`, the `-symbols.zip` from `<Prefix>\bin\*.pdb`.
  - With `-Installer`, calls `dist/windows/installer/build.ps1 -Stage <stage> -Version <v> -Arch <arch> -OutDir <OutDir> [-Test] [-SignCommand …]`.
  - Prints one `artifact: <path>` line per file. Exit 0, or 1 with the failed check.
- `installer/build.ps1` (Task 5): the parameters above.
  - Finds ISCC in this order: `$env:ISCC`, `$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe` (the owner's install), `${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe`, `$env:ProgramFiles\Inno Setup 6\ISCC.exe`. None → exit 2 with the R-M6-6 message, which lists the paths it looked in.
  - Writes `ghostty-<v>-windows-<arch>-setup[-test].exe`.
  - `build.ps1 -Probe` only looks for ISCC: exit 0 and the path, or exit 2 (used by `release.ps1`'s preflight).
- `release-version.ps1` (Task 8):
  ```
  release-version.ps1 -N <int> [-Rehearsal] [-RepoRoot <dir>]   # prints zon=…, version-string=…, tag=…, sha=…; exit 1 + rule
  release-version.ps1 -SelfTest
  ```
- `release.ps1` (Task 8):
  ```
  release.ps1 -N <int> [-Rehearsal] [-V1] [-OutDir <dir>] [-Force] [-SignCommand '<cmd {file}>']
              [-Arm64Abi gnu|msvc (default gnu)] [-Arm64TestExe] [-SkipTests] [-KeepPrefix] [-DryRun] [-Ci] [-Zig <path>] [-Lock <path>]
  ```
  - `-SkipTests` is refused without `-Rehearsal`.
  - `-DryRun` prints every step and command line and runs nothing heavy (preflight checks only).
  - `-Ci` (Task 12 only): no test-lock, Zig from PATH, refuses unless `GITHUB_ACTIONS=true`, and never prints publish commands.

---

### Task 1: `windows_version.zig`, `win-` tags in the build, one `-win.<N>` parser

**Review:** light.

**Files:**
- Create `src/build/windows_version.zig` (std only; imported by `build.zig`'s build module and by the main test exe).
- Modify:
  - `src/build/Config.zig`: in the `if (vsn.tag) |tag|` branch, `switch (windows_version.tagKind(tag))`, where `.tip, .fork` fall through to the dev version and `.upstream` keeps the `v<zon>` check. After `config.version` is set and the target is Windows, `windows_version.fileVersion(config.version)` is called; its error becomes a build error naming the version (R-M6-1).
  - `src/apprt/win32/update/release.zig`: `currentN` returns `windows_version.winN(version)`. Its test block gets `_ = windows_version;`, so the new tests run in the main test exe.

**Interfaces:**
- Produces:
  ```zig
  // src/build/windows_version.zig
  pub const TagKind = enum { tip, fork, upstream };
  pub fn tagKind(tag: []const u8) TagKind;                       // "tip" → tip; "win-" prefix → fork; else upstream
  pub fn winN(version: []const u8) ?u32;                         // "<zon>-win.<N>" at the end, canonical digits only
  pub const Error = error{ BadWinSuffix, NTooLarge };
  pub fn fileVersion(v: std.SemanticVersion) Error![4]u16;       // {major, minor, patch, N or 0}; each ≤ 65535
  pub fn rcHeader(alloc: Allocator, v: std.SemanticVersion, debug: bool, exe: Exe) (Error || Allocator.Error)![]u8;
  pub const Exe = enum { ghostty, tmux };                        // picks FileDescription / OriginalFilename
  ```
  `rcHeader` emits exactly these `#define`s: `GHOSTTY_FILEVERSION`, `GHOSTTY_VERSION_STR`, `GHOSTTY_FILEFLAGS`, `GHOSTTY_FILE_DESCRIPTION`, `GHOSTTY_ORIGINAL_FILENAME`. The version string is semver, so it needs no escaping; the function asserts `[0-9A-Za-z.+-]`.
- [ ] **Step 1: Failing tests** (in `windows_version.zig`):
  - `"windows version: tag kinds"`: `tip` → tip; `win-1.3.2-dev-3`, `win-x` → fork; `v1.3.2`, `foo` → upstream.
  - `"windows version: winN"`: `1.3.2-dev-win.3` → 3; `1.3.2-win.0` → 0; `-win.07`, `-win.+5`, `-win.1_0`, `-win.x`, `-win.` → null; `1.3.2-dev` → null; `1.3.2-dev-win.3+abc` → null.
  - `"windows version: fileVersion"`: `1.3.2-dev-win.7` → `{1,3,2,7}`; `1.3.2-dev` → `{1,3,2,0}`; `1.3.2-win.65536` → `NTooLarge`; `1.3.2-dev-win.07` → `BadWinSuffix`.
  - `"windows version: rc header"`:
    - `1.3.2-dev-win.7`, ghostty, release: the output contains `#define GHOSTTY_FILEVERSION 1,3,2,7`, `#define GHOSTTY_VERSION_STR "1.3.2-dev-win.7"`, `#define GHOSTTY_FILEFLAGS 0x2L`, `"Ghostty"`, `"ghostty.exe"`;
    - tmux, Debug, `1.3.2`: `0x1L`, `"Ghostty tmux shim"`, `"tmux.exe"`.
  - `"win32 update: currentN delegates"`: the existing `currentN` cases still pass, and `1.3.2-dev-win.07` → null (canonical now).
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="windows version"` → FAIL (file missing).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify.**
  - `-Dtest-filter="windows version"` and `"win32 update"` pass; `LOCK ZIG build -j6` passes.
  - Tag check: `git tag win-0.0.0-0`, then `LOCK ZIG build -h > /dev/null` exits 0 (before the change it panics), then `git tag -d win-0.0.0-0`. Never push this tag.
- [ ] **Step 5: Commit** `git commit -m "build(windows): version helper, win- tags no longer panic the build, one -win.N parser"`

### Task 2: Version resources in `ghostty.exe` and `tmux.exe`

**Review:** light.

**Files:**
- Create:
  - `dist/windows/versioninfo.rc`: the one `VS_VERSION_INFO VERSIONINFO` block of R-M6-2. It includes `ghostty_version.h`, uses only the `GHOSTTY_*` macros, `ProductName` is a literal, and `Translation 0x0409, 1200`.
  - `dist/windows/tmux.rc`: `#pragma code_page(65001)`, `LANGUAGE 0, 0`, the icon `1 ICON "ghostty.ico"`, `#include "versioninfo.rc"`. No manifest.
- Modify:
  - `dist/windows/ghostty.rc`: `#pragma code_page(65001)` first; the commented VERSIONINFO block replaced by `#include "versioninfo.rc"`; manifest and icon unchanged.
  - `src/build/GhosttyExe.zig`: on Windows, `b.addWriteFiles()` adds `ghostty_version.h` = `windows_version.rcHeader(…, .ghostty)`, passed as `include_paths` of `addWin32ResourceFile`.
  - `src/build/GhosttyTmuxShim.zig`: the same with `.tmux` and `dist/windows/tmux.rc`. The module stays `link_libc = false`.
- [ ] **Step 1: Build check** (no Zig test can read a linked resource):
  - `LOCK ZIG build -j6 --prefix zig-out-ver -Dversion-string=1.3.2-dev-win.7`;
  - then, for both exes, `powershell -NoProfile -Command "(Get-Item zig-out-ver/bin/ghostty.exe).VersionInfo | Format-List *"`.

  Before the change, FileVersion is empty → FAIL.
- [ ] **Step 2: Implement** R-M6-2.
- [ ] **Step 3: Verify.**
  - Both exes show:
    - FileVersion `1.3.2-dev-win.7`; FileMajorPart…FilePrivatePart `1 3 2 7`; ProductVersion `1.3.2-dev-win.7`;
    - ProductName `Ghostty — Unofficial Windows port` (em dash intact);
    - the FileDescription and OriginalFilename per exe;
    - IsPreRelease `True`, IsDebug `True` (Debug build).
  - `ghostty.exe` keeps its manifest and icon; the manifest is covered by `dpi-sim` in G1.
  - `dumpbin /imports zig-out-ver\bin\tmux.exe` (if a VS developer prompt is present) lists only `KERNEL32.dll`/`ntdll.dll`.
  - A plain `LOCK ZIG build -j6` gives FilePrivatePart `0`.
  - `-Dversion-string=1.3.2-win.70000` fails with the R-M6-1 message.
  - Delete `zig-out-ver`.
- [ ] **Step 4: Commit** `git commit -m "build(windows): version resource and icon in ghostty.exe and tmux.exe"`

### Task 3: `+uninstall-explorer-integration --only-this-exe`

**Review:** opus (what an uninstaller deletes, R-M6-5).

**Files:**
- Modify:
  - `src/os/windows_explorer.zig`: `ownsKeyFor`.
  - `src/cli/explorer_integration.zig`: `UninstallOptions.@"only-this-exe": bool = false`, help text, the uninstall path passes the own exe path (`GetModuleFileNameW`, full path) when set, and the `--dry-run` line.
  - `test/windows/e2e/explorer-cli.ps1`: one dry-run case with the flag.

**Interfaces:**
- Produces:
  ```zig
  // windows_explorer.zig
  pub const PathEql = *const fn (a: []const u8, b: []const u8) bool;  // the CLI passes CompareStringOrdinal(ignoreCase); tests pass an ASCII fold
  pub fn ownsKeyFor(command: ?[]const u8, menu: ?[]const u8, exe: ?[]const u8, eql: PathEql) bool;
      // exe null → ownsKey(command, menu) (R-M5-5); else the command's first quoted token must eql exe
      // (a key with no command but our menu text still counts: a failed install of this exe)
  ```
- [ ] **Step 1: Failing tests:**
  - `"windows explorer: only-this-exe owns only the same exe"`: the command of `C:\A\ghostty.exe` vs exe `c:\a\GHOSTTY.EXE` → true; vs `C:\B\ghostty.exe` → false; exe null → the M5 answers; an unquoted or empty command → false.
  - `"explorer cli: --only-this-exe keeps a foreign verb"`:
    - setup: a private hive (`RegLoadAppKeyW`, M5 pattern) holds the three verbs naming `C:\Other\ghostty.exe`;
    - uninstall with the flag → all three kept, exit 0, one `kept (other ghostty.exe)` line per key;
    - without the flag → deleted;
    - the hive files are removed at the end.
  - `"explorer cli: dry-run uninstall --all --only-this-exe"`: prints the `delete … if its command names <exe>` lines and the AUMID/icon lines, and opens no key.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="windows explorer"` and `"explorer cli"` → FAIL.
- [ ] **Step 3: Implement** R-M6-5.
- [ ] **Step 4: Verify:** both filters pass; `LOCK ZIG build -j6`; the scenario parses; `E2E -Only explorer-cli` (no window; the implementer may run it, M5 exception).
- [ ] **Step 5: Commit** `git commit -m "feat(cli): +uninstall-explorer-integration --only-this-exe keeps other copies' verbs"`

### Task 4: `package.ps1` and the portable layout

**Review:** light.

**Files:** Create `dist/windows/package.ps1` (interface above) and `dist/windows/README-windows.txt`.

**What `package.ps1` does, in order:**
1. **Stage.** `<OutDir>\stage\ghostty-<v>-windows-<arch>\` from `-Prefix` (`bin\ghostty.exe`, `bin\tmux.exe`, the `share` allowlist of R-M6-3, repo `LICENSE`, `README-windows.txt`) or from `-FromZip` (extract, then the same checks).
2. **Verify.** Each failure prints `package: FAIL <check>` and exits 1:
   - the required files of R-M6-3;
   - VersionInfo of both exes: ProductVersion = `-Version`; FilePrivatePart = `N` or 0; ProductName as R-M6-2;
   - `-Version` contains `-win.` → it matches `-win.(0|[1-9][0-9]*)$`;
   - if `dumpbin.exe` is found through `vswhere`: `ghostty.exe` imports neither `winhttp.dll` nor `dbghelp.dll` (M5), and `tmux.exe` imports only `KERNEL32.dll`/`ntdll.dll` (M4). Not found → `package: SKIP imports (no dumpbin)`;
   - with `-Installer`: the AUMID string in `installer\ghostty.iss` equals the release `aumid` literal in `src/os/windows_explorer.zig`.
3. **Sign** with `-SignCommand`: `{file}` replaced by each exe path; a non-zero exit fails.
4. **Zip:** `[IO.Compression.ZipFile]::CreateFromDirectory(<stage dir>, <zip>, Optimal, $true)`, which keeps the top folder.
5. **Symbols** with `-Symbols`: `ghostty.pdb`, `tmux.pdb` from `<Prefix>\bin`. Missing → FAIL (release builds use `-Dstrip=false`), except with `-NoPdbOk`. `release.ps1` passes it for an arm64 `gnu` build (R-M6-11); the result is no symbols zip and one `package: SKIP symbols (gnu)` line.
6. **Installer** with `-Installer`: call `installer\build.ps1`. Exit 2 (no ISCC) passes through, so a run without ISCC says so plainly.
7. Print the `artifact:` lines; remove `stage`.

**`README-windows.txt`** (plain text, ≤ 80 columns):
- what this is (unofficial port, link to the fork);
- unsigned (SmartScreen "More info → Run anyway");
- portable use: run `ghostty.exe` from the folder, with `share` next to it;
- the config at `%USERPROFILE%\.config\ghostty\config.ghostty`;
- the data at `%LOCALAPPDATA%\ghostty` (logs, crash dumps, update state);
- Explorer integration with `ghostty.exe +install-explorer-integration`, reverted with `ghostty.exe +uninstall-explorer-integration --all` (portable copies run this before deleting the folder);
- `tmux.exe`, and the folder on PATH for the external tmux mode;
- `auto-update = off`;
- where the CHANGELOG is.

- [ ] **Step 1: Failing check.** `PS dist/windows/package.ps1 -Prefix zig-out -Version 1.3.2-dev -Arch x64 -OutDir <scratch>` on a Debug `zig-out` without the compiled terminfo must exit 1 with `package: FAIL share\terminfo\78\xterm-ghostty`. Before the script exists → FAIL trivially.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Verify:**
  - the parse check;
  - the Debug `zig-out` with `-AllowNoTic` → the zip exists, has one top folder, `LICENSE` and `README-windows.txt`, and no `.pdb`;
  - an empty `-Prefix` → exit 1 with `ghostty.exe`;
  - `-FromZip <that zip>` → the same zip contents;
  - delete `<scratch>`.

  The VersionInfo check fails until Task 2 lands: run it with Task 2's build if that has landed, otherwise G1 covers it. The report says which.
- [ ] **Step 4: Commit** `git commit -m "build(windows): package.ps1 stages, verifies and zips the portable build"`

### Task 5: Inno Setup installer

**Review:** opus (what the installer and uninstaller write and delete, R-M6-4).

**Files:** Create `dist/windows/installer/ghostty.iss` and `dist/windows/installer/build.ps1` (interface above).

**`ghostty.iss` structure.** Preprocessor defines come from `build.ps1`: `AppVersion`, `Arch` (`x64`/`arm64`), `Stage`, `OutDir`, and optionally `GhosttyTest` and `Sign`.
- `#define AppAumid "com.mitchellh.ghostty.windows-unofficial"` (checked by Task 4).
- `[Setup]`:
  - `AppName=Ghostty`, `AppVerName=Ghostty {#AppVersion} (unofficial Windows port)`, `AppVersion`, `AppPublisher=Ghostty Windows port (unofficial)`, `AppPublisherURL=https://github.com/Denmurzik/ghostty`;
  - every R-M6-4 key;
  - `Compression=lzma2/max`, `SolidCompression=yes`, `OutputBaseFilename=ghostty-{#AppVersion}-windows-{#Arch}-setup` (with a `-test` suffix for the test variant), `UsedUserAreasWarning=no`;
  - `VersionInfoVersion` = the 4-part FILEVERSION (passed by `build.ps1` from `-Version`);
  - `#ifdef Sign` → `SignTool=signtool` and `SignedUninstaller=yes`.
- `[Tasks]` `explorer` and `desktopicon`, both `Flags: unchecked`, under `#ifndef GhosttyTest`.
- `[Files]` `Source: "{#Stage}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs`.
- `[Icons]` per R-M6-4, under `#ifndef GhosttyTest`.
- `[Run]` "Launch Ghostty" (`postinstall nowait skipifsilent`).
- `[UninstallRun]` per R-M6-4, with `--dry-run` appended under `#ifdef GhosttyTest`.
- `[Code]` the Explorer step of R-M6-4.

**`build.ps1`:** derives `VersionInfoVersion` with the Task 4 rule (`-win.<N>` → 4th part), runs `ISCC /Q /DAppVersion=… /DArch=… /DStage=… /DOutDir=… [/DGhosttyTest] [/DSign /Ssigntool=<cmd with $f>] ghostty.iss`, and prints `artifact:`.

- [ ] **Step 1: Self-test** `build.ps1 -SelfTest`: pure checks of the ISCC argument list for x64, arm64, test and sign (no ISCC needed). Before implementation → FAIL.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Verify:**
  - the parse check and `-SelfTest`;
  - `build.ps1 -Probe` finds the owner's `%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe` (owner decision 2). With `$env:ISCC` set to a missing file, it exits 2 with the R-M6-6 message;
  - ISCC compiles the release and the test variant, x64 and arm64, from a Task 4 stage (an `-AllowNoTic` stage is fine). Install nothing; delete the outputs.
- [ ] **Step 4: Commit** `git commit -m "build(windows): per-user Inno Setup installer with AUMID shortcut and opt-in Explorer integration"`

### Task 6: e2e `package-portable.ps1` (milestone M6)

**Review:** light.

**Files:**
- Create `test/windows/e2e/package-portable.ps1` (header `# e2e: milestone=M6 timeout=180 order=1000`).
- Modify `test/windows/e2e.ps1`: `ValidateSet` += `M6`, help text.

**Scenario:**
- Input `GHOSTTY_E2E_PACKAGE=<zip>`; unset → SKIP `no package (set GHOSTTY_E2E_PACKAGE)`.
- Extract into `<sandbox>\Portable Ж\` (space and Cyrillic).
- `ghostty.exe +version` (stdout redirected) prints the zip's version; `+list-themes --plain` prints ≥ 100 lines (resources found).
- Launch the extracted `ghostty.exe --class=<class>` with the sandbox env and `command = direct:cmd.exe /k` in the sandbox config. In the shell, through the M3 typed-input helper (oracle: the IPC `state`/screen text, as in M5 `term-terminfo.ps1`):
  - `echo %GHOSTTY_RESOURCES_DIR%` → under the extracted folder;
  - `echo %TERM%` → `xterm-ghostty`;
  - `where tmux` → first line is the extracted `tmux.exe`.
- Close, and assert that the process tree is gone.
- Moved share: rename `share` to `share.off`, launch → `TERM=xterm-256color` and one warning line in the sandbox log, no crash; rename it back.
- Assert that nothing new appeared in the extracted folder (file list before and after).

- [ ] **Step 1:** Write the scenario; make it parse; `E2E -Only package-portable` without the env → SKIP (the implementer may run this SKIP path; no window).
- [ ] **Step 2: Commit** `git commit -m "test(windows): e2e package-portable runs the zip from a spaced Cyrillic path"`

### Task 7: e2e `installer-test.ps1` (milestone M6)

**Review:** opus (owner safety: the only installer run on the owner's machine outside the manual checks).

**Files:** Create `test/windows/e2e/installer-test.ps1` (`# e2e: milestone=M6 timeout=300 order=1001`).

**Scenario:**
- Input `GHOSTTY_E2E_SETUP=<…-setup-test.exe>`. Unset, or a name not ending in `-setup-test.exe` → SKIP. The name check is a guard: never the real installer.
- **Read-only snapshot** (`reg query`, no writes) of:
  - `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall` (subkey names);
  - the three `HKCU\Software\Classes\…\shell\GhosttyOpenHere` keys;
  - `HKCU\Software\Classes\AppUserModelId\com.mitchellh.ghostty.windows-unofficial*`;
  - the Start-menu `Programs` folder listing.
- **Install:** `setup /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOICONS /DIR="<sandbox>\Inst Ж" /LOG="<sandbox>\setup.log"`, environment = the sandbox env plus `GHOSTTY_WIN32_TEST_HIVE=<sandbox>\hive.dat`. Wait ≤ 120 s.
- **Assert after install:** the files = the stage list + `unins000.exe`, `unins000.dat`; `+version` → the version; a GUI start with `--class` shows a window; close it.
- **User data:** drop `user-note.txt` into the install dir and a config sentinel into the sandbox config.
- **Uninstall:** `unins000.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=…`, same env. The uninstaller re-launches itself from `%TEMP%`, so wait until `unins000.exe` is gone (≤ 60 s, poll every 500 ms).
- **Assert after uninstall:**
  - only `user-note.txt` remains in the install dir;
  - the config sentinel is intact;
  - the uninstall log shows that the `[UninstallRun]` entry ran;
  - the snapshot equals the one before.
- **`finally`:** kill own processes; delete the sandbox dirs and the hive files.

- [ ] **Step 1:** Write it; make it parse; the SKIP path runs without a window.
- [ ] **Step 2: Commit** `git commit -m "test(windows): e2e installer-test installs and uninstalls the test installer in a sandbox"`

### Task 8: Local release script, tag validation, notes, `RELEASING.md`

**Review:** opus (release integrity, owner safety on a low-RAM machine, R-M6-6/7).

**Files:** Create:
- `dist/windows/release-version.ps1` (interface above). It reads:
  - `build.zig.zon` with a regex on `.version = "…"`;
  - `git tag -l "win-*"`, `git status --porcelain`, `git rev-parse HEAD`;
  - `git merge-base --is-ancestor HEAD origin/windows`.

  No network. `-SelfTest` runs the pure table:
  - a valid case;
  - `N` = `07`, `+5`, `65536`;
  - a zon mismatch;
  - `N` not above the existing max;
  - a duplicate `N`;
  - `-Rehearsal` with `N` other than 0 refused.
- `dist/windows/release.ps1` (interface above). Steps in order. Each step prints `== <n>/<total> <name>`, appends to `<OutDir>\release.log`, and stops the run on failure, naming the step:
  1. **Preflight:**
     - `release-version.ps1`;
     - `OutDir` (default `zig-out-release\<version>`) absent, or `-Force`; `git check-ignore` confirms that it is ignored;
     - Zig and the test-lock found;
     - `tic.exe` found;
     - ISCC found (`installer\build.ps1 -Probe`);
     - the VS ARM64 MSVC libraries found through `vswhere -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64` (only with `-Arm64Abi msvc`);
     - free physical memory ≥ 3 GB (`Win32_OperatingSystem.FreePhysicalMemory`).
  2. **Unit tests:** the three groups of R-M6-6, then `test-tmux-shim`, each as `bash <lock> -- <zig> build test -j6 …` with a 1500 s timeout and the RAM check before it. The pass/skip/fail counts are parsed from the output and written to `tests.txt`.
  3. **Build x64:** `bash <lock> -- <zig> build -j6` with the R-M6-3 flags, `--prefix <OutDir>\prefix-x64`.
  4. **Build arm64:** the same with `aarch64-windows-<abi>` and `--prefix <OutDir>\prefix-arm64`. With `-Arm64TestExe`, then the ARM64 test exe of R-M6-6, never run, zipped as `ghostty-<v>-windows-arm64-tests.zip`. It is not in `SHA256SUMS.txt` or `publish.txt`.
  5. **Package:** `package.ps1 -Prefix … -Installer -Symbols [-SignCommand …]` per arch, into `<OutDir>`.
  6. **Check:** `<OutDir>\prefix-x64\bin\ghostty.exe +version` prints the version.
  7. **Sums:** `SHA256SUMS.txt` (`Get-FileHash`, lower-case hex, two spaces, file name), written to a temp file and renamed when complete.
  8. **Notes:** `release-notes.md` from the template, with the counts from `tests.txt` and no local paths.
  9. **Publish commands:** printed and written to `publish.txt` per R-M6-7. Nothing is executed. The prefixes are removed unless `-KeepPrefix`.

  `-DryRun` runs step 1 and prints steps 2–9 with their exact command lines.
- `dist/windows/release-notes.md`: a template with `{{VERSION}}`, `{{TAG}}`, `{{V1_LINE}}`, `{{TESTS}}`, `{{ARM64_LINE}}`, `{{SHA256SUMS}}`.
- `docs/windows/RELEASING.md`, the owner's runbook:
  1. One-time setup: `gh auth login` (Inno Setup is already installed; the VS ARM64 component only for `-Arm64Abi msvc`, needs admin).
  2. `git fetch --tags origin`; the next `N`; the CHANGELOG entry.
  3. `PS dist/windows/release.ps1 -N <N> [-V1]`, about 1–2 h with RAM checks; do not run other builds meanwhile.
  4. Smoke the local artifacts (the owner part of § M6 exit checklist).
  5. Optional signing (R-M6-8).
  6. Run the printed commands.
  7. Check the update toast from an older build.
  8. A bad release: delete the release and the tag; `N` is burned; release `N+1`.

- [ ] **Step 1:**
  - `release-version.ps1 -SelfTest` → FAIL before implementation;
  - `release.ps1 -DryRun -N 1` → FAIL before implementation.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Verify:**
  - parse checks; `-SelfTest`;
  - `release.ps1 -Rehearsal -N 0 -DryRun` on this machine: preflight passes or names exactly what is missing (ISCC; the VS ARM64 component only with `-Arm64Abi msvc`), and the printed command lines match the R-M6-3 flags and the R-M6-7 commands (marked REHEARSAL);
  - `release.ps1 -N 0 -SkipTests -DryRun` → refused;
  - `git grep -n "gh release\|git push" dist/windows/*.ps1` shows them only inside printed strings.
- [ ] **Step 4: Commit** `git commit -m "build(windows): local release script with tag validation, unit groups, sums, notes and printed publish commands"`

### Task 9: Release rehearsal on the owner's machine (lead) and 9.n fixes

**Files:** none planned. Each 9.n touches only the files its note names (the Task 4/5/8 files).

- [ ] **Step 1:** Preflight only: ISCC is already installed (owner decision 2); ARM64 uses the default `gnu` ABI (R-M6-11), so no VS change is needed.
- [ ] **Step 2:** `PS dist/windows/release.ps1 -Rehearsal -N 0 -Arm64TestExe` (no `-SkipTests`), started with `run_in_background`. Record the wall time per step and the lowest free memory seen.
- [ ] **Step 3:** On its output:
  - `GHOSTTY_E2E_PACKAGE=<x64 zip>` `E2E -Only package-portable`;
  - build the test setup with `PS dist/windows/package.ps1 -FromZip <x64 zip> -Version <zon>-win.0 -Arch x64 -OutDir <scratch> -Installer -Test`, then `GHOSTTY_E2E_SETUP=<…-setup-test.exe>` `E2E -Only installer-test`;
  - check the arm64 zip, setup and symbols listing and the VersionInfo (no run).
- [ ] **Step 4:** For each failure, a 9.n note: step, log excerpt (no user name), evidence. Fix, then re-run the failing step or the rehearsal. Commits `git commit -m "fix(release): <summary>"`.

### Task 10: Docs — CHANGELOG, SPEC, DECISIONS amendment, feature checklist, test README

**Review:** lead.

**Files:** Modify:
- `docs/windows/CHANGELOG.md`: an M6 section with what ships, the artifact names, install/portable/uninstall behaviour, the version scheme, the local release path, and the gaps of R-M6-9.
- `docs/windows/SPEC.md`:
  - §13 as built: names, layout, installer keys, `--only-this-exe`, tag `win-*`, local release script and printed publish, signing hook. This replaces "tag `v*`" and the CI line;
  - §3: release flags with `-Dstrip=false`;
  - §16 R15/R16: the outcome;
  - §17 M6: plan link, then "done" in Task 11;
  - §18: R-M6-1…11.
- `docs/windows/DECISIONS.md`, "Release": one dated line, "2026-10-28 (owner): releases are built locally with `dist/windows/release.ps1`; GitHub Actions is optional and manual-only".
- `docs/windows/feature-checklist.md`: rows for zip, installer, version resource, release script; every row `done`, `manual` or a gap.
- `test/windows/README.md`: the M6 scenarios and their env (`GHOSTTY_E2E_PACKAGE`, `GHOSTTY_E2E_SETUP`) and the installer safety rule.
- [ ] **Step 1:** Write. **Step 2: Commit** `git commit -m "docs(windows): M6 release docs, SPEC packaging as built, local release path"`

### Task 11: Release candidate, v1.0 acceptance, owner sign-off

**Review:** lead + owner.

- [ ] **Step 1:** Upstream rebase per SPEC §17, if the lead takes it now (the zon, and so the tag's `<zon>`, may change).
- [ ] **Step 2 (owner, or the lead with the owner's go; local, not outward-facing):** `git fetch --tags origin`; `PS dist/windows/release.ps1 -N 1 -V1`. The output dir holds 6 artifacts, `SHA256SUMS.txt`, `release-notes.md` and `publish.txt`.
- [ ] **Step 3 (lead, owner's machine, the usual lock):**
  - extract the x64 zip to `<scratch>`, set `GHOSTTY_E2E_EXE=<scratch>\…\ghostty.exe`, and run `E2E -Milestone all`: all green, SKIPs only for documented reasons, including `package-portable` and `installer-test` with this RC's zip and a test setup made from it;
  - the RAM/latency rows of § budget (`m6-rc` rows in the CSVs);
  - `test/windows/claude-team.ps1` against the RC (as in M4; the owner's login; the owner's go for the token cost).
- [ ] **Step 4 (owner):** the manual lines of § M6 exit checklist, on the **local** artifacts.
- [ ] **Step 5:** Record `docs/windows/m6/acceptance.md`; amend SPEC §17 (M6 done) and the CHANGELOG acceptance line. Commit `git commit -m "docs(windows): M6 acceptance — Windows port v1.0"`.
- [ ] **Step 6 (owner):** push the `windows` branch, then run the commands in `publish.txt` (tag, push the tag, `gh release create … --prerelease`). Then the update-check line of the checklist.

### Task 12 (optional): `workflow_dispatch`-only GitHub Actions workflow

**Review:** opus (supply chain). Optional. No task, gate or release depends on it. It is useful once the owner confirms R-M6-6's free-runner ruling, because it gives automated ARM64 unit tests.

**Files:**
- Create:
  - `.github/workflows/windows-ci.yml`;
  - `dist/windows/ci/install-zig.ps1` (download from `https://ziglang.org/download/0.17.0/`, a pinned SHA-256, append to `$env:GITHUB_PATH`; refuses outside `GITHUB_ACTIONS=true`);
  - `dist/windows/ci/installer-smoke.ps1` (refuses outside CI). It runs:
    1. the real silent install with `/TASKS="explorer,desktopicon"`;
    2. asserts: the files, `Ghostty.lnk` with `System.AppUserModel.ID` = the release AUMID, the three verbs naming the installed exe, the `{37134A5A-…}_is1` key, `+version`, `+list-themes --plain` ≥ 100 lines;
    3. a sentinel config;
    4. uninstall and wait;
    5. asserts: everything above gone, the sentinel intact.
- Modify `dist/windows/release.ps1`: the `-Ci` mode.

**Workflow:**
- `on: workflow_dispatch` only, with inputs `n` (default 0) and `rehearsal` (default true); `permissions: contents: read`.
- Jobs:
  - x64 `release.ps1 -Ci` on `windows-2025` (Inno via `choco install innosetup` pinned version), then upload the artifacts to the run;
  - the three unit groups on `windows-11-arm` (`continue-on-error: true`);
  - `installer-smoke` x64 (gating), plus arm64 on `windows-11-arm` (`continue-on-error: true`).
- Only `actions/checkout`, `actions/upload-artifact`, `actions/download-artifact`, each pinned by full SHA. No cache, no secrets.

- [ ] **Step 1:** `install-zig.ps1 -SelfTest`, `installer-smoke.ps1 -SelfTest` (the guards refuse locally, exit 3, nothing touched) → FAIL before implementation.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Verify:**
  - parse checks, the self-tests;
  - `git grep -n "^on:\|push:\|schedule:\|pull_request" .github/workflows/windows-ci.yml` shows only `workflow_dispatch`;
  - the `uses:` lines are all `@<40 hex>`;
  - no `secrets.`.

  A real run needs the owner's push and dispatch.
- [ ] **Step 4: Commit** `git commit -m "ci(windows): optional manual-only workflow with ARM64 unit tests and installer smoke"`

### Task 13: `THIRD_PARTY_NOTICES.txt` and its coverage check

**Review:** light (lead reads the licence list).

**Files:**
- Create:
  - `dist/windows/THIRD_PARTY_NOTICES.txt`;
  - `dist/windows/third-party-check.ps1`.
- Modify `dist/windows/package.ps1`: stage the file at the zip root; add it to the required files; run the check before zipping.

**Steps:**
- [ ] **Step 1: Failing check.** `third-party-check.ps1 -RepoRoot .` → exit 1, because the file is missing.
  - The check reads the dependency names of `build.zig.zon` (and of `pkg/*/build.zig.zon`).
  - Each name must have a `== <name> ==` section in the notices file, or be in the script's exclusion table with a one-line reason.
  - Its `-SelfTest` covers: a section present; an exclusion; a missing name → fail.
- [ ] **Step 2: Decide what ships.** Find what the Windows exes really compile, link or embed:
  - `src/build/SharedDeps.zig` and `GhosttyTmuxShim.zig` (`tmux.exe` is std only);
  - the embedded fonts in `src/font/embedded.zig`;
  - the `share` content (iTerm2 colour schemes).

  Everything else goes in the exclusion table with its reason, for example: GTK/Wayland/fontconfig/`gtk4_layer_shell`/`libintl` Linux only; `macos`/`zig_objc`/`apple_sdk` macOS only; `android_ndk`; `zig_js`; `translate_c` build-time only; `sentry` if not linked on Windows.
- [ ] **Step 3: Write the file** (UTF-8, no BOM):
  - a header naming the port, Ghostty's own MIT licence pointer (`LICENSE`), and the date;
  - then one section per component: name, version or commit (from `build.zig.zon`), upstream URL, licence name, and the full licence text copied from the fetched package (`zig-pkg`/the Zig cache) or from `src/font/res/{OFL,MIT}.txt`.
  - It contains no local paths.
- [ ] **Step 4: Verify:**
  - parse checks; `-SelfTest`; the check passes on the repo;
  - `package.ps1` on the Debug `zig-out` with `-AllowNoTic` → the zip has `THIRD_PARTY_NOTICES.txt` at its root;
  - the Task 5 installer installs it automatically, because the stage is the source.
- [ ] **Step 5: Commit** `git commit -m "docs(windows): third-party notices shipped in the zip and installer, with a coverage check"`

## M6 exit checklist (v1.0 gate; owner signs, PASS/FAIL per line)

1. **Release run.**
   - `release.ps1 -N 1 -V1` finished, with the three unit groups and `test-tmux-shim` green (`tests.txt`).
   - Both arches built and packaged: 2 zips, 2 setups, the x64 symbols zip (and the arm64 one only if its build gave PDBs, R-M6-11), and `SHA256SUMS.txt` matching them.
   - `publish.txt` names the built commit.
   - The wall time and RAM low point are recorded.
2. **Version.**
   - `+version` of the RC prints `<zon>-win.1`.
   - Properties → Details of both exes (x64 and arm64) shows FileVersion `<maj>.<min>.<patch>.1`, ProductName `Ghostty — Unofficial Windows port`, and the icon.
   - A local build at the tagged commit does not panic and is not `-win.`.
3. **e2e.** `E2E -Milestone all` green on x64 with the RC exe: the M1–M6 scenarios, with `package-portable` on the RC zip and `installer-test` on a test setup made from it.
4. **Budgets.** The RC rows within § RAM and latency budget.
5. **Claude Code.** The `claude-team.ps1` agent-team run passes against the RC (DECISIONS v1.0 gate).
6. **Feature checklist** closed: every row done, manual or a documented gap (DECISIONS v1.0 gate).
7. **ARM64** (owner checks; recorded, never blocking — owner decision 4): built and packaged (line 1); the `-arm64-tests.zip` test exe run on an ARM64 device (exit code), or the optional Task 12 run, or N/A.
7a. **Third-party notices.** `THIRD_PARTY_NOTICES.txt` is at the zip root and in the install dir; `third-party-check.ps1` passed in the release run (owner decision 1).
8. **Owner manual checks** (x64, the owner's real account, on the local artifacts before publishing):
   - **Install.** The setup runs without a UAC prompt; the SmartScreen warning is as documented; it installs to `%LOCALAPPDATA%\Programs\Ghostty`; there is a Start-menu entry; "Launch Ghostty" opens a window in `%USERPROFILE%`.
   - **Pin and toasts.** Pin from Start: the jump list shows New Window, New Tab and the profiles. Toasts show under "Ghostty" with the icon, and the running window groups with the pinned icon (AUMID).
   - **Explorer.** With the checkbox ticked: "Open Ghostty here" on a folder, a folder background and `C:\` (through "Show more options").
   - **Upgrade.** Over the same version while Ghostty runs with a shell, and while only the tray icon runs: the Restart Manager page appears, Ghostty closes, the upgrade completes, the verbs are still there.
   - **Uninstall.**
     - Gone: the app dir, the Start entry, the verbs, the Apps & features entry.
     - Kept: `%USERPROFILE%\.config\ghostty` and `%LOCALAPPDATA%\ghostty\logs`.
     - A portable copy's verbs (made with `+install-explorer-integration` from an extracted zip before the uninstall) are still there and point to the portable exe.
   - **Portable.** The zip runs from a path with spaces and from a USB/read-only folder; `+uninstall-explorer-integration --all` cleans up after it.
   - **ARM64 smoke** (on an ARM64 device; else N/A recorded; not blocking): the arm64 setup installs, Ghostty opens, Git Bash prompt, a split, `tmux.exe -V`, uninstall.
   - **After publishing (Task 11 step 6):** the pre-release page shows the 7 assets, and the checksums match the local ones. A local ReleaseFast build with `-Dversion-string=<zon>-win.0` and `auto-update = check` shows the update toast for it, and the click opens the release page.
9. **Docs.** CHANGELOG M6; SPEC §3, §13, §17, §18 R-M6-*; the DECISIONS line; RELEASING.md; README-windows.txt in the zip.
10. **Gaps accepted by the owner:** R-M6-9.

Owner sign-off: name, date, tag, PASS/FAIL per line, decision (publish / fix and release `N+1`).

## Self-review

- **Owner scope → tasks:**

  | Owner requirement | Tasks |
  |---|---|
  | x64 + ARM64 portable zip | 4, 8 (both arches), 9 |
  | Inno Setup installer, x64 + ARM64 | 5, 8 |
  | Version resource (FILEVERSION/PRODUCTVERSION, ProductName, icon) in both exes | 1, 2 |
  | `-Dversion-string=<zon>-win.<N>`, tag `win-<zon>-<N>`, pre-release; `Config.zig` and `win-` tags | 1 (R-M6-1), 8 (R-M6-7) |
  | Update check sees the releases | R-M5-9 unchanged; smoke before the upload (R-M6-7); exit checklist 8 |
  | **Local** release script: builds both, headless unit filters through the lock, zip + symbols + installers, SHA256, tag rules, printed `git tag`/`git push`/`gh release create … --prerelease --draft` | 8 (R-M6-6/7), 9 |
  | Workflow `workflow_dispatch` only, nothing depends on it; free public runners as an overturnable ruling | R-M6-6, Task 12 |
  | ARM64 cross-built locally; ARM64 tests an owner check, non-blocking | R-M6-6, 8 (`-Arm64TestExe`), exit checklist 7 |
  | Third-party notices in zip + installer | 13 (R-M6-10) |
  | ISCC found in the owner's per-user path or Program Files, clear failure otherwise | 5 (`build.ps1 -Probe`), 8 (preflight) |
  | `GITHUB_TOKEN` only; signing hook, owner signs manually (gap) | R-M6-8, 4, 5, 8 |
  | Per-user, no admin; Start shortcut with AUMID | 5 (R-M6-4) |
  | Opt-in Explorer integration; uninstall reverts with `--all` | 3, 5 |
  | terminfo files; `tmux.exe` next to `ghostty.exe` | 4 (required files), 5 |
  | Uninstaller removes only its own; never the config | 3, 5, 7; exit checklist 8 |
  | v1.0 acceptance checklist (E2E all green x64, ARM64 smoke by owner) | 11, § M6 exit checklist |
  | Owner-machine safety (HKCU, network, GUI only via `e2e.ps1`, RAM) | § Owner safety, 7 (`/DGhosttyTest`), 8 (RAM checks, three groups, no network) |
- **Waves against `Files:`:**

  | Wave | Task | Files |
  |---|---|---|
  | W1 | 1 | `src/build/windows_version.zig`, `src/build/Config.zig`, `update/release.zig` |
  | W1 | 3 | `windows_explorer.zig`, `src/cli/explorer_integration.zig`, `explorer-cli.ps1` |
  | W1 | 4 | `dist/windows/package.ps1`, `README-windows.txt` |
  | W2 | 2 | `dist/windows/{ghostty.rc,tmux.rc,versioninfo.rc}`, `GhosttyExe.zig`, `GhosttyTmuxShim.zig` |
  | W2 | 5 | `dist/windows/installer/{ghostty.iss,build.ps1}` |
  | W2 | 6 | `e2e/package-portable.ps1`, `e2e.ps1` |
  | W3 | 7 | `e2e/installer-test.ps1` |
  | W3 | 8 | `release.ps1`, `release-version.ps1`, `release-notes.md`, `docs/windows/RELEASING.md` |
  | W3 | 13 | `THIRD_PARTY_NOTICES.txt`, `third-party-check.ps1`, `package.ps1` |
  | W4 | 10 | CHANGELOG, SPEC, DECISIONS, feature checklist, test README |
  | opt | 12 | `windows-ci.yml`, `ci/install-zig.ps1`, `ci/installer-smoke.ps1`, `release.ps1` (`-Ci`) |

  No file is shared inside a wave (Task 8 calls `package.ps1` but does not edit it). Cross-wave chains: `package.ps1` 4 → 13 → 9.n; `ghostty.iss` 5 → 9.n; `release.ps1` 8 → 9.n → 12. `src/build/Config.zig` follows the M5 19.n `tic` fix. `installer/build.ps1 -Probe`, used by Task 8, is part of Task 5's file (the interface says it exits 0/2 without compiling).
- **Names defined once:**

  | Task | Names |
  |---|---|
  | 1 | `windows_version.{TagKind,tagKind,winN,Error,fileVersion,rcHeader,Exe}` (`release.currentN` delegates) |
  | 2 | `GHOSTTY_*` rc macros (from Task 1's header), `versioninfo.rc` |
  | 3 | `windows_explorer.{PathEql,ownsKeyFor}`, `UninstallOptions.only-this-exe` |
  | 4 | the `package.ps1` parameters |
  | 5 | the `AppId`s, `AppAumid`, the `GhosttyTest`/`Sign` defines, `build.ps1 -Probe` |
  | 8 | the `release.ps1`/`release-version.ps1` parameters, the unit groups, the notes placeholders, `publish.txt` |
  | 12 | `windows-ci.yml` inputs |
  | 13 | the notices section format `== <name> ==`, the exclusion table |
- **Review Focus → tests:** 1 → Tasks 3, 7; 2 → owner checklist; 3 → Tasks 1, 4, 8, 9; 4 → Tasks 8, 9; 5 → Task 6; 6 → Task 9, owner checklist.
- **Proportion:** the code blocks are signatures, interfaces and command lines only.
- **Known risks:**
  - ARM64 ships with the MinGW ABI (R-M6-11): no PDBs for ARM64 dumps, and a different C runtime than x64. `-Arm64Abi msvc` needs an admin VS change.
  - A full `release.ps1` run is long (three test compiles, two ReleaseFast builds, optionally the ARM64 test exe) on a 15.5 GB machine. The test-lock, the RAM checks and the step order keep it to one heavy step at a time.
  - ARM64 is unit-tested only by the owner on a device, or by the optional Task 12.

### Owner decisions (2026-10-28, binding; answers to revision 1's open questions)

1. **Third-party notices: yes, before the v1.0 publication.** `THIRD_PARTY_NOTICES.txt` covers the fonts, FreeType, HarfBuzz, the Zig dependencies and the rest, and ships in the zip and the installer (R-M6-10, Task 13).
2. **Inno Setup is already installed** per-user at `%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe`. `release.ps1` looks there and in Program Files, and fails clearly otherwise (R-M6-6, Tasks 5 and 8).
3. **Per-machine install stays a v1.0 gap** (R-M6-4, R-M6-9).
4. **ARM64 checks do not block a release.** They are recorded owner checks (R-M6-6, exit checklist 7).

No open questions remain. The remaining overturnable lead rulings for the owner:
- R-M6-6: free public runners; the workflow is `workflow_dispatch` only until the owner re-enables triggers;
- R-M6-3: `-Dstrip=false` with symbols;
- R-M6-1: ignore rather than accept `win-` tags.
