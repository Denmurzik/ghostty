# M6 — Release (version resource, portable zip, Inno Setup installer, GitHub Actions, pre-release, v1.0 gate): Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the Windows port ships, for x64 and ARM64:
- `ghostty.exe` and `tmux.exe` with a Windows version resource (FILEVERSION/PRODUCTVERSION, ProductName, icon);
- a portable zip;
- a per-user Inno Setup installer (Start-menu shortcut with the app's AUMID, opt-in "Open Ghostty here", terminfo, `tmux.exe` next to `ghostty.exe`, an uninstaller that removes only what it installed);
- a GitHub Actions workflow that builds both arches, runs the headless unit tests, packages, and attaches everything to a **draft pre-release** when a `win-*` tag is pushed;
- the v1.0 acceptance checklist, signed by the owner.

Exit (SPEC §17 M6): the owner signs the acceptance checklist (§ M6 exit checklist).

**Architecture:**
- **Build.** A std-only helper `src/build/windows_version.zig` owns the version rules: `win-` tag handling, `-win.<N>` parsing, FILEVERSION and the generated `.rc` header. `Config.zig`, `GhosttyExe.zig` and `GhosttyTmuxShim.zig` call it. Its tests run in the main test exe.
- **Packaging.** PowerShell scripts under `dist/windows/` do the same thing on the owner's machine and on CI: stage, verify, zip, call ISCC, optionally sign. CI runs only scripts that are also runnable (and reviewed) locally; the YAML stays thin.
- **Installer.** One Inno Setup script for both arches (`/DArch=`). A `/DGhosttyTest` variant has no registry, no shortcuts and no Restart Manager, so a sandboxed e2e can install and uninstall it on the owner's machine.
- **CI.** One reusable workflow (build, test, package, installer smoke) is called by a branch workflow and by the tag workflow; only the tag workflow can create a release.

**Tech Stack:** Zig 0.17.0 (MSVC ABI, Zig's resource compiler), PowerShell 5.1 (scripts must run on the owner's machine and on `windows-2025`), Inno Setup 6.4+ (`ISCC.exe`, arm64 support), GitHub Actions (GitHub-hosted `windows-2025` and `windows-11-arm`), `gh` CLI with `GITHUB_TOKEN`.

**Spec:** `docs/windows/SPEC.md` (with `docs/windows/DECISIONS.md` the authority):
- §1 (non-goals: code signing, MSIX), §2 (`dist/windows/` layout), §3 (release recipe flags), §13 (packaging; as amended by M5 Task 20), §14 (RAM), §16 R15/R16, §17 M6, §18.3 (AUMID toasts).
- DECISIONS "Release" (zip + Inno on tag, no certificate, SmartScreen accepted) and the v1.0 gate (feature checklist closed, upstream + win32 tests, vttest-style checks, RAM, Claude Code tmux run, owner smoke of a pre-release).
- M5 hand-over: R-M5-5 (Explorer keys, `--all`, installer shortcut AUMID), R-M5-9/9a (update check, `<zon>-win.<N>`, `win-<zon>-<N>`, pre-releases, compare `N`), R-M5-7 (compiled terminfo, `-Dtic`).

Other inputs:
- Owner decisions for M6 (2026-10-28, binding; summarised in the Goal and Rulings).
- Memory rules: speed over ceremony; style follows macOS (not relevant here except the icon).
- Format and conventions: `docs/windows/plans/M5-windows-extras.md`, `docs/windows/plans/M5-preflight-review.md`.

**Starts** when M5 is accepted (Task 20) **and** the M5 19.n batch that touches `src/build/Config.zig` (`tic`) has landed. Tasks 3, 4 and 5 touch no M5-owned file in flight and may start once M5 W8 has started. Task numbers are identities, not order: the wave table is the execution order.

## Global Constraints

Carried from M1–M5 (every task implicitly includes these):

- Zig 0.17.0 at `C:\tools\zig-x86_64-windows-0.17.0\zig.exe` (full path). Shell: Git Bash. Target ABI MSVC. Minimum OS Windows 11 22H2 (Windows 10 best effort).
- Core edits only in "M6 core touch points". A cause found outside them: the implementer stops with evidence; the lead schedules an `n.1` task.
- Commits: no `Co-Authored-By` or similar trailers. Never `python -` (nor `python3 -` with a heredoc).
- Worktree bootstrap: `cmd //c mklink /J "<worktree>\zig-pkg" "C:\D\den4ik\Ghostty\zig-pkg"`. A worktree's first (cold) build runs with `run_in_background` under `timeout 1500` through the test-lock.
- **Privacy:** no Windows user name in any file, log excerpt or report. Paths are written as `%USERPROFILE%`, `%LOCALAPPDATA%`, `%APPDATA%`.
- **PowerShell scripts** target Windows PowerShell 5.1 (`powershell -NoProfile`), `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, no modules beyond the inbox ones. Each new script must parse:
  ```
  powershell -NoProfile -Command "[ScriptBlock]::Create((Get-Content -Raw <file>)) | Out-Null"
  ```

**Owner safety (M2–M5 rules, extended for M6).** None of these needs a per-run approval, because none touches owner state.

- **Harness.** e2e scenarios run only through `test/windows/e2e.ps1`: shared desktop lock, a per-scenario `class`, the sandbox env (`New-E2eSandbox`: `XDG_CONFIG_HOME`, `APPDATA`, `LOCALAPPDATA`, `USERPROFILE` under the sandbox). Every Ghostty a scenario starts gets `--class=<scenario class>`, is registered with `Register-OwnGhostty` and stopped in `finally`. Evidence images only through the guarded capture helpers.
- **Registry.** No test, scenario or implementer run writes the real `HKCU`/`HKLM`.
  - The Explorer CLI runs only with `--dry-run` or with `GHOSTTY_WIN32_TEST_HIVE=<file>` (M5 rule).
  - The **real** installer and uninstaller never run on the owner's machine in a test or an implementer run. They run on CI runners (ephemeral VMs) through `dist/windows/ci/installer-smoke.ps1`, which refuses to start unless `GITHUB_ACTIONS=true`, and in the owner's manual checks.
  - On the owner's machine only the `/DGhosttyTest` installer runs (R-M6-5): no uninstall key, no shortcuts, no Restart Manager session (its volatile `HKCU\Software\Microsoft\RestartManager` keys), no Explorer task, and its uninstaller calls the Explorer CLI with `--dry-run`. The scenario snapshots the relevant `HKCU` keys read-only before and after and asserts no change.
- **Files.** Packaging writes only under its `-OutDir` and a temp stage under it. Nothing writes `%LOCALAPPDATA%\Programs`, the Start menu, the desktop or `%USERPROFILE%\.config\ghostty` on the owner's machine, except the owner's manual checks.
- **Network.** No local test reaches the internet (M5 ruling C3 holds). CI jobs download Zig and the Zig package dependencies; that is CI, not the owner's machine.
- **Outward-facing actions** (push, tag, workflow dispatch, release edits, publishing) are done by the owner, or by the lead with the owner's explicit go for that action. Implementers never push, tag or call `gh`.
- **CI secrets:** `GITHUB_TOKEN` only. No signing certificate, no PAT, no other secret (R-M6-8).

Speed rules (owner 2026-10-26/28; unchanged):

- Builds and tests use `-j6` through the test-lock (3 slots, each checks ≥ 2 GB free). Bash timeout 600000. Prefer a focused `-Dtest-filter`; never the full suite locally.
- A ReleaseFast build with a different `-Dversion-string` rebuilds the whole exe: at most one such build per task, into its own `--prefix`.
- Implementers run unit tests, `LOCK ZIG build -j6`, script parse checks and the pure `-SelfTest` modes. The lead runs e2e scenarios in batches (G1, Task 12). CI changes are verified by the CI bring-up (Task 10), not locally.
- Up to 3 writers in flight; a task starts as soon as its dependencies have landed and its files do not collide.
- Every task: unit tests or a self-test, plus at most one e2e scenario.
- **Review tier** (stated per task): `light` = one batched sonnet review per wave; `opus` = per-task review for what an uninstaller deletes, owner safety, supply chain or release integrity.

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
| `dist/windows/ghostty.rc` | `#pragma code_page(65001)`, the commented VERSIONINFO block replaced by `#include "versioninfo.rc"` | 2 |
| `src/os/windows_explorer.zig` | `ownsKeyFor` (owner = this exe) | 3 |
| `src/cli/explorer_integration.zig` | `+uninstall-explorer-integration --only-this-exe` | 3 |

Not touch points: `src/apprt/win32/**` (other than `release.zig`), `src/termio/**`, `src/config/Config.zig`, `build.zig`, `build.zig.zon` (the zon version stays upstream's, R-M5-9a), the upstream workflows in `.github/workflows/` (R-M6-6).

### RAM and latency budget

Same binary as M5 except the version resource and `-Dstrip=false` (R-M6-3). Measured on the release candidate's x64 exe from the CI zip, with `test/windows/measure-ram.ps1` and `input-latency`, against the M5 acceptance rows re-measured the same day.

| Item | Budget | Measured by |
|---|---|---|
| RC `ghostty.exe`, default config, 1 window 1 surface, 30 s after start | ≤ M5 acceptance row + 1 MB | Task 12 |
| RC `tmux.exe` peak private (`display-message`) | ≤ 5 MB (SPEC §14) | Task 12 |
| Key echo, Ghostty-owned p95 | within +0.5 ms of M5 | Task 12 |
| Startup to first frame | within +10 ms of M5 | Task 12 |

Over budget: DONE_WITH_CONCERNS with numbers; if `-Dstrip=false` is the cause, R-M6-3's fallback applies (strip, ship no symbols).

## Review Focus

1. **The uninstaller removes exactly what the installer put there.**
   - Removed: installed files, the Start-menu (and optional desktop) shortcut, the uninstall entry, the Explorer verbs that name **this** `ghostty.exe`, the AUMID registration and the toast icon (`--all`).
   - Kept: `%USERPROFILE%\.config\ghostty\**`, `%LOCALAPPDATA%\ghostty\**` except the toast icon (logs, crash dumps, `update.json`), files the user added under the install dir (and so the dir itself), the verbs of another (portable) `ghostty.exe`.
   - Tests: Task 3 `windows explorer: only-this-exe …`, `explorer cli: --only-this-exe keeps a foreign verb`; Task 7 `installer-test.ps1`; Task 8 `installer-smoke.ps1`; owner checklist.
2. **Install, upgrade or uninstall while Ghostty runs.** Cases: a window with shells; tray only (no window); a Claude Code team using `tmux.exe` from the install dir.
   - Expected: the Restart Manager page lists Ghostty; "close automatically" ends it through `WM_QUERYENDSESSION`/`WM_ENDSESSION` (the tray window already answers both); no half-replaced install dir (Inno's retry/abort on a locked file); the upgrade keeps the Explorer verbs and the remembered tasks.
   - Tests: owner checklist (the only place the real installer meets real processes).
3. **One version everywhere.** Tag `win-<zon>-<N>` ↔ `build.zig.zon` version ↔ `-Dversion-string=<zon>-win.<N>` ↔ `+version` ↔ VersionInfo (FileVersion `major.minor.patch.N`) ↔ the update check's `N`.
   - A malformed tag never produces a release; `N` only grows and is never reused; a local build at a tagged commit neither panics nor counts as a release.
   - Tests: Task 1 `windows version: …`; Task 9 `release-version.ps1 -SelfTest`; Task 4 package verification; Task 10 CI runs.
4. **CI supply chain and permissions.**
   - Only GitHub-owned actions, pinned by full commit SHA; Zig downloaded from ziglang.org and checked against a pinned SHA-256.
   - `permissions: contents: read` everywhere except the release job (`contents: write`); no `pull_request_target`; no secret but `GITHUB_TOKEN`; tag builds restore no cache.
   - A `win-*` tag on a commit outside `windows` history is refused.
   - Tests: review (opus) of Tasks 8 and 9; Task 10 runs a dry run first.
5. **The portable zip from odd places.** Paths with spaces, Cyrillic, over 260 characters, a read-only folder; a zip whose `share` folder was moved.
   - Expected: resources found (`share\terminfo\ghostty.terminfo` sentinel); `TERM` falls back to `xterm-256color` when the compiled entry is missing (R-M5-7); `tmux.exe` first on `PATH` inside sessions; nothing written next to the exe.
   - Tests: Task 6 `package-portable.ps1` (space + Cyrillic dir); owner checklist (USB/read-only).
6. **Release binaries run on every target machine.**
   - Always an explicit `-Dtarget=<arch>-windows-msvc`: CPU baseline, never the runner's native features (AVX-512 on the build VM must not leak into the exe).
   - The ARM64 MSVC cross-link uses the runner's VS ARM64 libraries (SPEC R15).
   - Tests: Task 10 (an ARM64 `+version` run on `windows-11-arm`); owner ARM64 smoke.

## Rulings (plan-m6, 2026-10-28; lead/owner may overturn; recorded in SPEC §18 by Task 11)

The owner's M6 decisions (binding, not re-asked):
- deliverables for x64 and ARM64 (zip, Inno installer, version resource in both exes);
- the version scheme of R-M5-9a;
- releases as GitHub pre-releases, attached to a draft on a `win-*` tag push; no secret beyond `GITHUB_TOKEN`;
- signing is manual, outside CI;
- per-user installer with the AUMID shortcut, opt-in Explorer integration, terminfo, `tmux.exe`; uninstall reverts with `--all` and never touches the config;
- the v1.0 checklist signed by the owner.

- **R-M6-1 `src/build/Config.zig` ignores `win-` tags.**
  - Today a commit whose exact tag is not `tip` and not `v<zon>` panics the build (`tagged releases must be in vX.Y.Z format`) unless `-Dversion-string` is given.
  - New rule: a tag starting with `win-` is treated like `tip`. The build falls through to the dev version `<zon-major.minor.patch>-<branch>+<hash>` (`HEAD` as branch in a detached CI checkout).
  - The release version comes **only** from `-Dversion-string=<zon>-win.<N>`. The release workflow validates the tag against `build.zig.zon` and passes it (R-M6-7).
  - Accepting the tag (deriving the version from it) was rejected: two sources of truth, and a local build at a release commit would silently turn on the update check.
  - Upstream `vX.Y.Z` behaviour is unchanged.
  - On a Windows target, a version whose string contains `-win.` must end in a canonical `N` (digits, no leading zero) with `N ≤ 65535`. Anything else is a build error naming the value. 65535 is the FILEVERSION field limit.
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
  - The zip has one top folder `ghostty-<version>-windows-<arch>\` so that extraction never spills files. Inside:
    - `ghostty.exe`, `tmux.exe`, `LICENSE`, `README-windows.txt`;
    - `share\` with the existing subfolders among `ghostty`, `terminfo`, `bash-completion`, `fish`, `zsh`, `vim`, `nvim`, `bat`, `man` (an allowlist; anything else the prefix has, e.g. Linux desktop files, is left out);
    - no `.pdb`.
  - Required, else packaging fails:
    - `share\ghostty\themes` (non-empty) and `share\ghostty\shell-integration`;
    - `share\terminfo\ghostty.terminfo` (the resources sentinel of `resourcesdir.zig`);
    - `share\terminfo\78\xterm-ghostty` (compiled, R-M5-7). Only a local run may waive it, with `-AllowNoTic`, and the waiver is printed.
  - **Release builds use** `-Doptimize=ReleaseFast -Demit-themes=true -Demit-terminfo=true -Dstrip=false -Dtic=<Git's tic.exe> -Dtarget=<x86_64|aarch64>-windows-msvc -Dversion-string=<v>`.
    - `-Dstrip=false` yields the PDBs (for the M5 crash dumps), shipped only in `-symbols.zip`. It also keeps frame pointers and unwind tables, which help the dumps.
    - Cost if wrong (the Task 12 RAM/latency rows): drop to the default strip and ship no symbols.
- **R-M6-4 Installer** (`dist/windows/installer/ghostty.iss`).
  - **Privileges and arch.**
    - Per-user only: `PrivilegesRequired=lowest`, no override dialog; an all-users install is a v1.0 gap.
    - `DefaultDirName={autopf}\Ghostty` (`%LOCALAPPDATA%\Programs\Ghostty`); `DisableProgramGroupPage=yes`.
    - `AppId={{37134A5A-16BD-4127-9CC0-134E0CF32BA5}`, fixed forever. The test variant uses `{{B6635077-20E7-4DDF-A062-7D9F8711ADF2}`.
    - x64: `ArchitecturesAllowed=x64compatible`, `ArchitecturesInstallIn64BitMode=x64compatible`. arm64: both `arm64`.
    - `MinVersion=10.0.17763` (the ConPTY floor; Windows 10 is best effort per DECISIONS).
  - **Files:** the zip's content (same stage, same allowlist); `UninstallDisplayIcon={app}\ghostty.exe`; `SetupIconFile=..\ghostty.ico`; `WizardStyle=modern`; English only; no license page (MIT, the file is installed).
  - **Shortcuts.**
    - `[Icons]` `{autoprograms}\Ghostty` → `{app}\ghostty.exe`, `WorkingDir: {%USERPROFILE}`, `AppUserModelID: "com.mitchellh.ghostty.windows-unofficial"` (the release `windows_explorer.aumid`; `package.ps1` checks they match).
    - The optional desktop shortcut (task `desktopicon`, unchecked) is the same.
  - **Explorer task `explorer`** (unchecked, label `Add "Open Ghostty here" to the Explorer folder menu`).
    - `[Code]` `CurStepChanged(ssPostInstall)` runs `{app}\ghostty.exe +install-explorer-integration` hidden and waits.
    - A non-zero exit code shows a suppressible warning and is logged; the install still succeeds.
    - Unticking it on an upgrade does not remove existing verbs (the uninstaller does).
  - **Uninstall.**
    - `[UninstallRun]` always runs `{app}\ghostty.exe +uninstall-explorer-integration --all --only-this-exe` (hidden, waits, `RunOnceId: "ExplorerRevert"`). It runs whether or not the task was ticked: `--all` also removes the AUMID key and toast icon that the app creates at runtime (SPEC §13), and `--only-this-exe` (R-M6-5) keeps a portable copy's verbs.
    - No `[UninstallDelete]`: Inno removes exactly the files it logged. User-added files keep the dir.
  - **Running Ghostty:** `CloseApplications=yes`, `RestartApplications=no`. No PATH change (SPEC §13). Postinstall "Launch Ghostty" (`postinstall nowait skipifsilent`).
  - **`/DGhosttyTest`** (Task 7 only): `CreateUninstallRegKey=no`, `CloseApplications=no`, no `[Icons]`, no `[Tasks]`, `[UninstallRun]` gets `--dry-run`, the output name ends `-setup-test.exe`.
- **R-M6-5 `+uninstall-explorer-integration --only-this-exe`.**
  - With the flag, a verb key counts as ours only if its `command\(default)` names this very exe. The comparison is of full paths, `CompareStringOrdinal(…, TRUE)` on UTF-16 (the file system's rule).
  - Without the flag, the R-M5-5 rule (any `ghostty.exe`) is unchanged.
  - `--all`'s AUMID and toast-icon removal is not affected.
  - `--dry-run` with the flag prints `delete <key> if its command names <exe>`.
- **R-M6-6 CI layout.**
  - Three new workflows: `windows-build.yml` (reusable, `workflow_call`), `windows-ci.yml` (push to `windows`, `workflow_dispatch`) and `windows-release.yml` (push of a tag `win-*`, `workflow_dispatch` dry run).
  - Upstream workflow files are not edited: clean merges. Their jobs ask for `namespace-profile-*` runners the fork does not have. The owner disables them in the fork's Actions settings (G2 prerequisite).
  - **Runners:** `windows-2025` (pinned image, not `windows-latest`) for x64 builds, both cross builds, x64 tests and the x64 installer smoke. `windows-11-arm` for the ARM64 unit tests and the ARM64 installer smoke, both `continue-on-error: true` (non-gating, recorded in the release notes; the owner cannot fix ARM64 locally). If the fork is private and `windows-11-arm` is unavailable, those jobs are skipped by a repository variable `WINDOWS_ARM_RUNNER != 'off'`.
  - **ARM64** is cross-built on x64 with `aarch64-windows-msvc`. If the runner lacks the VS ARM64 libraries, the fallback `aarch64-windows-gnu` (SPEC R15, the target M2–M5 compiled locally) is taken only by a lead ruling recorded in the release notes.
  - **Unit tests** (headless, x64 gating):
    - `zig build test -Dtest-filter="win32 " -Dtest-filter="windows " -Dtest-filter="tmux shim " -Dtest-filter="Exec: w" -Dtest-filter="d3d11 " -Dtest-filter="terminal" -Dtest-filter="config" -Dtest-filter="input" -Dtest-filter="font"` (the M1–M5 exit filters), plus `zig build test-tmux-shim`. Timeout 90 min (SPEC R4).
    - A test that needs an interactive desktop and fails only on the runner is skipped under `GITHUB_ACTIONS=true` with `error.SkipZigTest` and a one-line reason. Each such skip is a 10.n task, listed in the CHANGELOG.
  - **Zig:** `dist/windows/ci/install-zig.ps1` downloads `zig-<x86_64|aarch64>-windows-0.17.0.zip` from `https://ziglang.org/download/0.17.0/`, checks it against the SHA-256 pinned in the workflow, and puts it on `PATH`.
  - **Actions:** only `actions/checkout`, `actions/upload-artifact`, `actions/download-artifact`, `actions/cache`, each pinned by full commit SHA with the tag in a comment.
  - **Cache:** branch builds cache the Zig global cache keyed on `build.zig.zon` + Zig version; tag builds restore none.
  - **Permissions:** `contents: read` at the top; `contents: write` only on the release job; `concurrency` per ref.
- **R-M6-7 Release.**
  - **Tag** `win-<zon>-<N>`, annotated, pushed by the owner. `N` starts at **1**, is fork-wide and never reused, even for a deleted release.
  - **Validation** (`dist/windows/ci/release-version.ps1`, R-M5-9a rules) refuses when:
    - the tag does not match `^win-(?<zon>[0-9A-Za-z.-]+)-(?<n>0|[1-9][0-9]*)$`;
    - `<zon>` is not `build.zig.zon`'s `.version`;
    - `N > 65535`;
    - `N` is not greater than every other `win-*` tag's `N`;
    - the tagged commit is not an ancestor of `origin/windows`.
  - **Release** created with `gh release create <tag> --draft --prerelease --verify-tag`.
    - Title `Ghostty <zon>-win.<N> (unofficial Windows port)`.
    - Notes from `dist/windows/release-notes.md`: version, "Windows port v1.0" on the acceptance release, unsigned/SmartScreen note, install and portable notes, the CI test summary (ARM64 rows marked non-gating), checksums.
    - Assets: the 2 zips, 2 setups, 2 symbol zips, `SHA256SUMS.txt`.
    - A re-run on a tag whose release exists uploads with `--clobber` only while it is still a draft; a published release is never touched by CI.
  - **Publishing** (draft → published pre-release) is the owner's manual step after the smoke. The update check ignores drafts (R-M5-9), so nothing is announced before that.
  - `release_channel` stays `tip` for `-win.<N>` builds (semver pre-release). At this plan's base it only shows in `+version` on Windows; the M5 19.n batch 2 "update channel" item may give it a meaning, and Task 1's implementer re-checks that the updater still looks only at `N` (R-M5-9a).
- **R-M6-8 Signing hook, no certificate in CI (gap).**
  - CI artifacts are unsigned (DECISIONS: SmartScreen warning accepted).
  - `package.ps1 -SignCommand '<command with {file}>'` signs `ghostty.exe` and `tmux.exe` in the stage before zipping. It passes `/DSign` plus `/Ssigntool=<command with $f>` to ISCC, so `setup.exe` and the uninstaller (`SignedUninstaller=yes`) are signed too.
  - The owner's manual path (RELEASING.md): `package.ps1 -FromZip <CI zip> -SignCommand … -Installer` on the owner's machine. It needs no Zig build, only ISCC and the owner's certificate. Then `gh release upload --clobber` the 4 re-signed assets and a regenerated `SHA256SUMS.txt` while the release is a draft.
  - The PDBs still match: signing does not change the code.
- **R-M6-9 What M6 does not do** (v1.0 gaps, in the CHANGELOG):
  - all-users install; a PATH entry for external tmux (documented instead);
  - MSIX and the Windows 11 top-level context menu;
  - signing in CI; winget/scoop manifests;
  - jump-list removal on uninstall (Explorer drops it when the shortcut is gone; the CLI has no COM, R-M5-5);
  - a third-party notices file beyond `LICENSE` (open question 1).

## Waves (parallelism)

≤ 3 tasks per wave; file sets inside a wave are strictly disjoint.

| Wave | Tasks | Depends on |
|---|---|---|
| W1 | 1 version helper + `win-` tags · 3 `--only-this-exe` · 4 `package.ps1` + `README-windows.txt` | M5 accepted, M5 19.n `Config.zig` landed (1); — (3, 4) |
| W2 | 2 version resources · 5 Inno script + `installer/build.ps1` · 6 `package-portable.ps1` scenario | 1 (2); 3+4 (5); 4 (6) |
| G1 | **Lead batch:** `RF -Dversion-string=<zon>-win.0`, `PS dist/windows/package.ps1 -Prefix zig-out-rf …`, `E2E -Only explorer-cli,package-portable,dpi-sim`; ISCC present → also the test installer | 2, 3, 5, 6 |
| W3 | 7 `installer-test.ps1` scenario · 8 CI reusable build + branch CI + installer smoke | 5 (7); 2+4+5 (8) |
| W4 | 9 release workflow, tag validation, notes, `RELEASING.md` (alone) | 8 |
| G2 | **Task 10 (lead + owner):** owner prerequisites, first CI run, release dry run, 10.n fixes | 7, 9 |
| W5 | 11 docs: CHANGELOG, SPEC, feature checklist, test README (alone) | 10.* |
| W6 | 12 release candidate tag, v1.0 acceptance, owner sign-off (lead + owner) | 11 |

Hot-file chains (every file touched by more than one task):
- `dist/windows/package.ps1`: 4 → 10.n.
- `dist/windows/installer/ghostty.iss`: 5 → 10.n.
- `test/windows/e2e.ps1` (`ValidateSet` += `M6`): 6 only.
- `test/windows/e2e/explorer-cli.ps1`: 3 only.
- `.github/workflows/windows-build.yml`: 8 → 10.n. `windows-release.yml`: 9 → 10.n.
- `docs/windows/{SPEC.md, CHANGELOG.md, feature-checklist.md}`, `test/windows/README.md`: 11 (+ Task 12 acceptance lines).

Interfaces fixed by this plan (so W2/W3 tasks run in parallel):
- `package.ps1` (Task 4):
  ```
  package.ps1 (-Prefix <dir with bin\ and share\> | -FromZip <zip>) -Version <v> -Arch x64|arm64 -OutDir <dir>
              [-Installer] [-Test] [-Symbols] [-SignCommand '<cmd {file}>'] [-AllowNoTic]
  ```
  - Writes `<OutDir>\ghostty-<v>-windows-<arch>.zip`; with `-Symbols`, the `-symbols.zip` from `<Prefix>\bin\*.pdb`.
  - With `-Installer`, calls `dist/windows/installer/build.ps1 -Stage <stage> -Version <v> -Arch <arch> -OutDir <OutDir> [-Test] [-SignCommand …]`.
  - Prints one `artifact: <path>` line per file. Exit 0, or 1 with the failed check.
- `installer/build.ps1` (Task 5): the parameters above. Finds ISCC (`$env:ISCC`, then PATH, then `${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe`, then `$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe`), else exit 2 with `ISCC not found`. Writes `ghostty-<v>-windows-<arch>-setup[-test].exe`.
- `windows-build.yml` (Task 8):
  ```yaml
  on:
    workflow_call:
      inputs:
        version-string: { type: string, default: "" }  # "" = <zon>-ci.<run_number> (branch builds; no -win., so no update check)
        release:        { type: boolean, default: false } # true = tag build: no cache, -Symbols
  ```
  Uploads the artifacts `ghostty-windows-x64` and `ghostty-windows-arm64`, each with the zip, setup and symbols zip of its arch, plus `test-summary.md`.

---

### Task 1: `windows_version.zig`, `win-` tags in the build, one `-win.<N>` parser

**Review:** light.

**Files:**
- Create `src/build/windows_version.zig` (std only; imported by `build.zig`'s build module and by the main test exe).
- Modify:
  - `src/build/Config.zig`: in the `if (vsn.tag) |tag|` branch, `switch (windows_version.tagKind(tag))`, where `.tip, .fork` fall through to the dev version and `.upstream` keeps the `v<zon>` check. After `config.version` is set and the target is Windows, `windows_version.fileVersion(config.version)` is called, and its error becomes a build error naming the version (R-M6-1).
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
  - `"windows version: rc header"`: for `1.3.2-dev-win.7`, ghostty, release, the output contains `#define GHOSTTY_FILEVERSION 1,3,2,7`, `#define GHOSTTY_VERSION_STR "1.3.2-dev-win.7"`, `#define GHOSTTY_FILEFLAGS 0x2L`, `"Ghostty"`, `"ghostty.exe"`. For tmux, Debug, `1.3.2`: `0x1L`, `"Ghostty tmux shim"`, `"tmux.exe"`.
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
    - FileVersion `1.3.2-dev-win.7`, FileMajorPart…FilePrivatePart `1 3 2 7`, ProductVersion `1.3.2-dev-win.7`;
    - ProductName `Ghostty — Unofficial Windows port` (the em dash intact), the FileDescription and OriginalFilename per exe, IsPreRelease `True`, IsDebug `True` (Debug build).
  - `ghostty.exe` keeps its manifest and icon (the manifest is covered by `dpi-sim` in G1).
  - `dumpbin /imports zig-out-ver\bin\tmux.exe` (VS developer prompt, if present) lists only `KERNEL32.dll`/`ntdll.dll`.
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
  - `"explorer cli: --only-this-exe keeps a foreign verb"`: a private hive (`RegLoadAppKeyW`, M5 pattern) holds the three verbs naming `C:\Other\ghostty.exe`. Uninstall with the flag → all three kept, exit 0, one `kept (other ghostty.exe)` line per key. Without the flag → deleted. The hive files are removed at the end.
  - `"explorer cli: dry-run uninstall --all --only-this-exe"`: prints the `delete … if its command names <exe>` lines and the AUMID/icon lines, and opens no key.
- [ ] **Step 2: Run** `LOCK ZIG build test -j6 -Dtest-filter="windows explorer"` and `"explorer cli"` → FAIL.
- [ ] **Step 3: Implement** R-M6-5.
- [ ] **Step 4: Verify** that both filters pass; `LOCK ZIG build -j6`; the scenario parses; `E2E -Only explorer-cli` (no window, implementer may run it, M5 exception).
- [ ] **Step 5: Commit** `git commit -m "feat(cli): +uninstall-explorer-integration --only-this-exe keeps other copies' verbs"`

### Task 4: `package.ps1` and the portable layout

**Review:** light.

**Files:**
- Create `dist/windows/package.ps1` (interface above) and `dist/windows/README-windows.txt`.

**What `package.ps1` does, in order:**
1. **Stage.** `<OutDir>\stage\ghostty-<v>-windows-<arch>\` from `-Prefix` (`bin\ghostty.exe`, `bin\tmux.exe`, the `share` allowlist of R-M6-3, repo `LICENSE`, `README-windows.txt`) or from `-FromZip` (extract, then the same checks).
2. **Verify** (each failure prints `package: FAIL <check>` and exits 1):
   - the required files of R-M6-3;
   - VersionInfo of both exes: ProductVersion = `-Version`; FilePrivatePart = `N` or 0; ProductName as R-M6-2;
   - `-Version` contains `-win.` → it matches `-win.(0|[1-9][0-9]*)$`;
   - if `dumpbin.exe` is found through `vswhere`: `ghostty.exe` imports neither `winhttp.dll` nor `dbghelp.dll` (M5); `tmux.exe` imports only `KERNEL32.dll`/`ntdll.dll` (M4). Not found → `package: SKIP imports (no dumpbin)`;
   - the AUMID string in `installer\ghostty.iss` equals the release `aumid` literal in `src/os/windows_explorer.zig` (only when `-Installer`).
3. **Sign** with `-SignCommand`: `{file}` replaced by each exe path; a non-zero exit fails.
4. **Zip:** `[IO.Compression.ZipFile]::CreateFromDirectory(<stage dir>, <zip>, Optimal, $true)`, which keeps the top folder.
5. **Symbols** with `-Symbols`: `ghostty.pdb`, `tmux.pdb` from `<Prefix>\bin`. Missing → FAIL (release builds use `-Dstrip=false`).
6. **Installer** with `-Installer`: call `installer\build.ps1`. Exit 2 (no ISCC) passes through, so a local run without ISCC says so plainly.
7. Print `artifact:` lines; remove `stage`.

**`README-windows.txt`** (plain text, ≤ 80 columns):
- what this is (unofficial port, link to the fork);
- unsigned (SmartScreen "More info → Run anyway");
- portable use: run `ghostty.exe` from the folder, which needs `share` next to it;
- the config at `%USERPROFILE%\.config\ghostty\config.ghostty`;
- the data at `%LOCALAPPDATA%\ghostty` (logs, crash dumps, update state);
- Explorer integration: `ghostty.exe +install-explorer-integration`, and revert with `ghostty.exe +uninstall-explorer-integration --all` (portable copies run this before deleting the folder);
- `tmux.exe` and the external tmux mode needing the folder on PATH;
- `auto-update = off`;
- where the CHANGELOG is.

- [ ] **Step 1: Failing check.** `PS dist/windows/package.ps1 -Prefix zig-out -Version 1.3.2-dev -Arch x64 -OutDir <scratch>` on a Debug `zig-out` without the compiled terminfo → must exit 1 with `package: FAIL share\terminfo\78\xterm-ghostty`. Before the script exists → FAIL trivially.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Verify:**
  - the parse check;
  - the Debug `zig-out` with `-AllowNoTic` → the zip exists, has one top folder, `LICENSE` and `README-windows.txt`, no `.pdb`;
  - an empty `-Prefix` → exit 1 with `ghostty.exe`;
  - `-FromZip <that zip>` → the same zip contents;
  - delete `<scratch>`.

  The VersionInfo check fails until Task 2 lands. Run it with Task 2's build if it has landed; otherwise G1 covers it, and the report says which.
- [ ] **Step 4: Commit** `git commit -m "build(windows): package.ps1 stages, verifies and zips the portable build"`

### Task 5: Inno Setup installer

**Review:** opus (what the installer and uninstaller write and delete, R-M6-4).

**Files:**
- Create `dist/windows/installer/ghostty.iss` and `dist/windows/installer/build.ps1` (interface above).

**`ghostty.iss` structure** (preprocessor defines from `build.ps1`: `AppVersion`, `Arch` (`x64`/`arm64`), `Stage`, `OutDir`, optional `GhosttyTest`, `Sign`):
- `#define AppAumid "com.mitchellh.ghostty.windows-unofficial"` (checked by Task 4).
- `[Setup]`:
  - `AppName=Ghostty`, `AppVerName=Ghostty {#AppVersion} (unofficial Windows port)`, `AppVersion`, `AppPublisher=Ghostty Windows port (unofficial)`, `AppPublisherURL=https://github.com/Denmurzik/ghostty`;
  - every R-M6-4 key, plus `Compression=lzma2/max`, `SolidCompression=yes`, `OutputBaseFilename=ghostty-{#AppVersion}-windows-{#Arch}-setup` (`-test` suffix), `VersionInfoVersion` = the 4-part FILEVERSION (passed by `build.ps1` from `-Version`), `UsedUserAreasWarning=no`;
  - `#ifdef Sign` → `SignTool=signtool` and `SignedUninstaller=yes`.
- `[Tasks]` `explorer` and `desktopicon`, both `Flags: unchecked`, under `#ifndef GhosttyTest`.
- `[Files]` `Source: "{#Stage}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs`.
- `[Icons]` per R-M6-4, under `#ifndef GhosttyTest`.
- `[Run]` "Launch Ghostty" (`postinstall nowait skipifsilent`).
- `[UninstallRun]` per R-M6-4; `--dry-run` appended under `#ifdef GhosttyTest`.
- `[Code]` the Explorer step of R-M6-4.

**`build.ps1`:** derives `VersionInfoVersion` with the Task 4 rule (`-win.<N>` → 4th part), runs `ISCC /Q /DAppVersion=… /DArch=… /DStage=… /DOutDir=… [/DGhosttyTest] [/DSign /Ssigntool=<cmd with $f>] ghostty.iss`, and prints `artifact:`.

- [ ] **Step 1: Self-test** `build.ps1 -SelfTest`: pure checks of the ISCC argument list for x64, arm64, test and sign (no ISCC needed). Before implementation → FAIL.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Verify:**
  - the parse check and `-SelfTest`.
  - If ISCC is on this machine: `ISCC /Q` compiles the release and the test variant from a Task 4 stage (`-AllowNoTic` stage is fine). Install nothing.
  - If ISCC is absent: report `ISCC absent: compile check moved to G1/Task 10` (do not install Inno Setup without the owner; open question 2).
- [ ] **Step 4: Commit** `git commit -m "build(windows): per-user Inno Setup installer with AUMID shortcut and opt-in Explorer integration"`

### Task 6: e2e `package-portable.ps1` (milestone M6)

**Review:** light.

**Files:**
- Create `test/windows/e2e/package-portable.ps1` (header `# e2e: milestone=M6 timeout=180 order=1000`).
- Modify `test/windows/e2e.ps1`: `ValidateSet` += `M6`, help text.

**Scenario:**
- Input: `GHOSTTY_E2E_PACKAGE=<zip>`; unset → SKIP `no package (set GHOSTTY_E2E_PACKAGE)`.
- Extract into `<sandbox>\Portable Ж\` (space and Cyrillic).
- `ghostty.exe +version` (stdout redirected) prints the zip's version; `+list-themes --plain` prints ≥ 100 lines (resources found).
- Launch the extracted `ghostty.exe --class=<class>` with the sandbox env and `command = direct:cmd.exe /k` in the sandbox config. In the shell, through the M3 typed-input helper:
  - `echo %GHOSTTY_RESOURCES_DIR%` → under the extracted folder;
  - `echo %TERM%` → `xterm-ghostty`;
  - `where tmux` → first line is the extracted `tmux.exe`.

  Oracle: the IPC `state`/screen text, as in M5 `term-terminfo.ps1`.
- Close and assert that the process tree is gone.
- Moved share: rename `share` to `share.off`, launch → `TERM=xterm-256color` and one warning line in the sandbox log, no crash; rename back.
- Assert that nothing new appeared in the extracted folder (file list before/after).

- [ ] **Step 1:** Write the scenario; make it parse; `E2E -Only package-portable` without the env → SKIP (implementer may run this SKIP path, no window).
- [ ] **Step 2: Commit** `git commit -m "test(windows): e2e package-portable runs the zip from a spaced Cyrillic path"`

### Task 7: e2e `installer-test.ps1` (milestone M6)

**Review:** opus (owner safety: the only installer run on the owner's machine).

**Files:** Create `test/windows/e2e/installer-test.ps1` (`# e2e: milestone=M6 timeout=300 order=1001`).

**Scenario:**
- Input: `GHOSTTY_E2E_SETUP=<…-setup-test.exe>`. Unset, or a name not ending `-setup-test.exe` → SKIP. The name check is a guard: never the real installer.
- **Read-only snapshot** (`reg query`, no writes) of:
  - `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall` (subkey names);
  - the three `HKCU\Software\Classes\…\shell\GhosttyOpenHere` keys;
  - `HKCU\Software\Classes\AppUserModelId\com.mitchellh.ghostty.windows-unofficial*`;
  - the Start-menu `Programs` folder listing.
- **Install:** `setup /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOICONS /DIR="<sandbox>\Inst Ж" /LOG="<sandbox>\setup.log"`, environment = sandbox env plus `GHOSTTY_WIN32_TEST_HIVE=<sandbox>\hive.dat`. Wait ≤ 120 s.
- **Assert after install:**
  - the files = the stage list + `unins000.exe`, `unins000.dat`;
  - `+version` → the version;
  - a GUI start with `--class` shows a window; close it.
- **User data:** drop `user-note.txt` into the install dir and a config sentinel into the sandbox config.
- **Uninstall:** `unins000.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=…` with the same env. The uninstaller re-launches itself from `%TEMP%`, so wait until `unins000.exe` is gone (≤ 60 s, poll 500 ms).
- **Assert after uninstall:**
  - only `user-note.txt` remains in the install dir;
  - the config sentinel is intact;
  - the uninstall log shows the `[UninstallRun]` entry ran;
  - the snapshot equals the one before.
- **Cleanup in `finally`:** kill own processes, delete the sandbox dirs and the hive files.

- [ ] **Step 1:** Write it; make it parse; the SKIP path runs without a window.
- [ ] **Step 2: Commit** `git commit -m "test(windows): e2e installer-test installs and uninstalls the test installer in a sandbox"`

### Task 8: CI — reusable build/test/package, branch CI, installer smoke

**Review:** opus (supply chain, permissions, R-M6-6).

**Files:**
- Create `.github/workflows/windows-build.yml` (reusable; interface above). Jobs:
  - `build` (matrix `arch: [x64, arm64]`, `windows-2025`, timeout 60 min):
    - `actions/checkout` with `fetch-depth: 0` (git describe, tags);
    - `ci/install-zig.ps1` (x86_64);
    - cache per R-M6-6 when not `release`;
    - `<v>` = the input, or, when it is empty, `<zon>-ci.<github.run_number>` (zon read from `build.zig.zon` with the Task 9 regex; every job computes the same value);
    - `zig build` with the R-M6-3 flags, `-Dversion-string=<v>` and `-Dtic="C:/Program Files/Git/usr/bin/tic.exe"`;
    - `package.ps1 -Prefix out -Version <v> -Arch <arch> -OutDir dist-out -Installer`, plus `-Symbols` when `release`;
    - upload `ghostty-windows-<arch>`.
  - `test-x64` (`windows-2025`, timeout 90 min): the R-M6-6 filters, then `zig build test-tmux-shim`. Writes the pass/fail/skip counts into `test-summary.md` (job output).
  - `test-arm64` (`windows-11-arm`, `continue-on-error: true`, the same, with `install-zig.ps1 -Arch aarch64`).
  - `installer-smoke` (matrix: x64 on `windows-2025`; arm64 on `windows-11-arm` with `continue-on-error: true`; `needs: build`): download the artifact, then run `ci/installer-smoke.ps1 -Setup <setup> -Zip <zip> -Version <v>`.
- Create `.github/workflows/windows-ci.yml`: `on: push: branches: [windows]` + `workflow_dispatch`; `uses: ./.github/workflows/windows-build.yml` with `version-string: ""`, `release: false`.
- Create `dist/windows/ci/install-zig.ps1` (`-Version -Arch -Sha256`; downloads to `$env:RUNNER_TEMP`, checks the hash, appends to `$env:GITHUB_PATH`; refuses without `GITHUB_ACTIONS=true`).
- Create `dist/windows/ci/installer-smoke.ps1`. It refuses unless `GITHUB_ACTIONS=true`. Steps:
  1. Real install `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /TASKS="explorer,desktopicon" /LOG=…`.
  2. Assert after install:
     - the files under `%LOCALAPPDATA%\Programs\Ghostty`;
     - `Ghostty.lnk` in the Start-menu `Programs` folder, with `System.AppUserModel.ID` (Shell.Application `ExtendedProperty`) = the release AUMID;
     - the three verbs, each naming the installed exe;
     - the `{37134A5A-…}_is1` uninstall key;
     - `+version` prints `-Version`;
     - `+list-themes --plain` ≥ 100 lines.
  3. Write `%USERPROFILE%\.config\ghostty\config.ghostty` = `# sentinel`.
  4. Uninstall `/VERYSILENT` and wait for `unins000.exe` to go.
  5. Assert after uninstall: the install dir gone, the shortcuts gone, the verbs gone, the uninstall key gone, the AUMID key gone, the sentinel config intact.
  6. Extract the zip to a spaced path and run `+version` there.
  7. Append a summary to `$env:GITHUB_STEP_SUMMARY`.
- [ ] **Step 1:**
  - `install-zig.ps1 -SelfTest` and `installer-smoke.ps1 -SelfTest`: the guard refuses outside CI (exit 3, nothing touched); pure path/argument helpers. Run locally → FAIL before implementation.
  - The workflows: the YAML is checked only by review here; Task 10 runs it.
- [ ] **Step 2: Implement.**
  - Pin each action by SHA and the Zig hash. The implementer reads the SHAs from the actions' release pages and the hash from `https://ziglang.org/download/index.json`; reading public metadata is not a test.
- [ ] **Step 3: Verify:**
  - parse checks and both `-SelfTest`s (outside CI they must refuse the real work);
  - `git grep -n "uses:" .github/workflows/windows-*.yml` shows only the four allowed actions, each `@<40 hex>`;
  - `git grep -n "secrets\." .github/workflows/windows-*.yml` shows nothing.
- [ ] **Step 4: Commit** `git commit -m "ci(windows): reusable build, test, package and installer smoke; branch CI"`

### Task 9: Release workflow, tag validation, release notes, `RELEASING.md`

**Review:** opus (release integrity, R-M6-7).

**Files:**
- Create `dist/windows/ci/release-version.ps1`:
  - `-Tag <tag> -RepoRoot <dir>` prints `version-string=<zon>-win.<N>` and `n=<N>`, or exits 1 with the R-M6-7 rule it broke. It reads `build.zig.zon` with a regex on `.version = "…"`, the other tags with `git tag -l "win-*"`, and checks ancestry with `git merge-base --is-ancestor <sha> origin/windows`.
  - `-SelfTest` runs the pure table: valid; `win-1.3.2-dev-007`; `win-1.3.2-dev-+5`; `win--7`; zon mismatch; `N` 65536; `N` not above the existing max; duplicate `N`.
- Create `dist/windows/release-notes.md`: a template with `{{VERSION}}`, `{{TAG}}`, `{{V1_LINE}}`, `{{TESTS}}`, `{{SHA256SUMS}}`.
- Create `.github/workflows/windows-release.yml`:
  - `on: push: tags: ["win-*"]` + `workflow_dispatch` with inputs `tag` (string) and `dry-run` (boolean, default true).
  - Jobs:
    - `version`: checkout `fetch-depth: 0`; `release-version.ps1`; outputs.
    - `build`: `uses: ./.github/workflows/windows-build.yml` with `version-string`, `release: true`.
    - `release` (`needs: [version, build]`, `if: !inputs.dry-run`, `permissions: contents: write`):
      1. Download both artifacts; build `SHA256SUMS.txt` (`Get-FileHash`, lower-case hex, two spaces, file name).
      2. Fill the notes; `{{V1_LINE}}` is empty unless the tag message contains `v1.0`.
      3. `gh release view <tag>`. Exists and published → fail without changes. Exists and draft → `gh release upload --clobber`. Missing → `gh release create <tag> --draft --prerelease --verify-tag --title … --notes-file …` with the 7 assets.
      4. `GH_TOKEN: ${{ github.token }}`.
    - A dry run uploads the artifacts to the run only.
- Create `docs/windows/RELEASING.md`, the owner's runbook:
  1. Preconditions (`windows-ci` green, the CHANGELOG entry, the next `N` from `git tag -l "win-*"`).
  2. `git tag -a win-<zon>-<N> -m "Ghostty <zon>-win.<N>"`, then `git push origin win-<zon>-<N>`.
  3. Wait for `windows-release`; check the draft's 7 assets.
  4. Smoke (the owner part of § M6 exit checklist).
  5. Optional manual signing (R-M6-8).
  6. Edit the notes, publish (keep "pre-release").
  7. Check the update toast from an older build.
  8. A bad release: delete the release and the tag; `N` is burned; tag `N+1`.
- [ ] **Step 1:** `release-version.ps1 -SelfTest` → FAIL before implementation.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Verify:**
  - parse checks; `-SelfTest`;
  - `release-version.ps1 -Tag win-<zon>-1 -RepoRoot .` locally (read-only git commands) → `version-string=<zon>-win.1` once `origin/windows` contains HEAD; else the ancestry error, which is also a pass of the check;
  - the same `uses:`/`secrets.` greps as Task 8.
- [ ] **Step 4: Commit** `git commit -m "ci(windows): draft pre-release on win-* tags with tag validation, notes and runbook"`

### Task 10: CI bring-up (lead + owner) and 10.n fixes

**Files:** none planned. Each 10.n touches only the files its note names (Task 4/5/8/9 files, or a test that gets a CI skip).

- [ ] **Step 1: Owner prerequisites** (owner, outward-facing):
  - disable the upstream workflows in the fork's Actions settings;
  - set Actions "Workflow permissions" to read by default (the release job asks for write itself);
  - add a tag ruleset so that only the owner can create `win-*` tags;
  - set `WINDOWS_ARM_RUNNER` if the fork is private.
- [ ] **Step 2:** With the owner's go: push `windows`; `windows-ci` runs. Then `workflow_dispatch` of `windows-release` on `windows` with `tag = win-<zon>-0` and `dry-run = true`.

  In a dry run the tag need not exist: the validation checks the name, the zon, `N` against the existing tags and the dispatched commit's ancestry. It creates no tag and no release; the artifacts stay on the run.
- [ ] **Step 3:** For each failure, a 10.n note: job, step, log excerpt. Typical expected ones:
  - the ARM64 MSVC libraries (R-M6-6 fallback → lead ruling);
  - a desktop-bound unit test (CI skip);
  - an ISCC path;
  - `tic` on the runner.

  Fix, push (owner's go), re-run, until `windows-ci` is green and the dry run produces all 6 artifacts. Commits `git commit -m "fix(ci): <summary>"` / `git commit -m "test(windows): skip <test> on CI runners (<reason>)"`.
- [ ] **Step 4:** Download the dry-run x64 zip and setup to `<scratch>`. Run `E2E -Only package-portable` with `GHOSTTY_E2E_PACKAGE`. Run `installer-test` only with a locally built `-setup-test.exe` (or SKIP).

### Task 11: Docs — CHANGELOG, SPEC, feature checklist, test README

**Review:** lead.

**Files:** Modify:
- `docs/windows/CHANGELOG.md`: an M6 section. What ships, the artifact names, install/portable/uninstall behaviour, the version scheme, the gaps of R-M6-9 and the CI skips of 10.n.
- `docs/windows/SPEC.md`:
  - §13 as built: names, layout, installer keys, `--only-this-exe`, tag `win-*`, draft pre-release, signing hook; replaces "tag `v*`";
  - §3: the release flags with `-Dstrip=false`;
  - §16 R15/R16: the outcome;
  - §17 M6: plan link, then "done" in Task 12;
  - §18: R-M6-1…9.
- `docs/windows/feature-checklist.md`: rows for zip, installer, version resource, CI, release; every row `done`, `manual` or a gap.
- `test/windows/README.md`: the M6 scenarios and their env (`GHOSTTY_E2E_PACKAGE`, `GHOSTTY_E2E_SETUP`), and the installer safety rule.
- [ ] **Step 1:** Write. **Step 2: Commit** `git commit -m "docs(windows): M6 release docs, SPEC packaging as built, feature checklist rows"`

### Task 12: Release candidate, v1.0 acceptance, owner sign-off

**Review:** lead + owner.

- [ ] **Step 1:** Upstream rebase per SPEC §17, if the lead takes it now (then the zon may change, and so the tag's `<zon>`).
- [ ] **Step 2 (owner):** tag `win-<zon>-1` with the message `Windows port v1.0 candidate`; push; the draft pre-release appears with 7 assets.
- [ ] **Step 3 (lead, owner's machine, the usual lock):**
  - Extract the x64 zip to `<scratch>`, set `GHOSTTY_E2E_EXE=<scratch>\…\ghostty.exe`, and run `E2E -Milestone all`. All green; SKIPs only for the documented reasons.
  - The RAM/latency rows of § budget (`m6-rc` rows in the CSVs).
  - `test/windows/claude-team.ps1` against the RC (as in M4; the owner's login, the owner's go for the token cost).
- [ ] **Step 4 (owner):** the manual lines of § M6 exit checklist.
- [ ] **Step 5:** Record `docs/windows/m6/acceptance.md`; amend SPEC §17 M6 done, and the CHANGELOG acceptance line. Commit `git commit -m "docs(windows): M6 acceptance — Windows port v1.0"`.
- [ ] **Step 6 (owner):** publish the draft as a pre-release (RELEASING.md step 6).

## M6 exit checklist (v1.0 gate; owner signs, PASS/FAIL per line)

1. **CI on the RC tag.**
   - `windows-release` green: x64 and ARM64 build, the x64 unit tests, the x64 installer smoke.
   - ARM64 unit tests and installer smoke recorded (non-gating).
   - Tag validation passed. The draft has 2 zips, 2 setups, 2 symbol zips and `SHA256SUMS.txt`, and the hashes match.
2. **Version.**
   - `+version` of the RC prints `<zon>-win.1`.
   - Properties → Details of both exes shows FileVersion `<maj>.<min>.<patch>.1`, ProductName `Ghostty — Unofficial Windows port`, and the icon.
   - `+version` of a local build at the tagged commit does not panic and is not `-win.`.
3. **e2e.** `E2E -Milestone all` green on x64 with the RC exe (M1–M6 scenarios; `package-portable` with the RC zip; `installer-test` with a test setup, or SKIP with the reason).
4. **Unit tests.** The R-M6-6 filters green on CI. Locally, the M5 exit filters at the RC commit.
5. **Budgets.** The RC rows within § RAM and latency budget.
6. **Claude Code.** The `claude-team.ps1` agent-team run passes against the RC (DECISIONS v1.0 gate).
7. **Feature checklist** closed: every row done, manual or a documented gap (DECISIONS v1.0 gate).
8. **Owner manual checks** (x64, the owner's real account):
   - **Install.** The setup runs without a UAC prompt; the SmartScreen warning is as documented; it installs to `%LOCALAPPDATA%\Programs\Ghostty`; there is a Start-menu entry; "Launch Ghostty" opens a window in `%USERPROFILE%`.
   - **Pin and toasts.** Pin from Start: the jump list shows New Window, New Tab and the profiles. Toasts show under "Ghostty" with the icon; the running window groups with the pinned icon (AUMID).
   - **Explorer.** The Explorer checkbox ticked: "Open Ghostty here" on a folder, a folder background and `C:\` (via "Show more options").
   - **Upgrade.** An upgrade over the same version while Ghostty runs with a shell, and while only the tray icon runs: the Restart Manager page, Ghostty closes, the upgrade completes, the verbs are still there.
   - **Uninstall.** The app dir, Start entry and verbs are gone; Apps & features shows no entry; `%USERPROFILE%\.config\ghostty` and `%LOCALAPPDATA%\ghostty\logs` are kept; the verbs of a portable copy (made with `+install-explorer-integration` from an extracted zip before uninstalling) are still there and point to the portable exe.
   - **Portable.** The zip runs from a path with spaces and from a USB/read-only folder; `+uninstall-explorer-integration --all` cleans up after it.
   - **Update.** A local ReleaseFast build with `-Dversion-string=<zon>-win.0` and `auto-update = check` shows the update toast for the **published** RC (after step 6, or with a temporarily published test release), and the click opens the release page.
   - **ARM64 smoke** (owner, on an ARM64 device; else N/A recorded): the arm64 setup installs, Ghostty opens, Git Bash prompt, a split, `tmux.exe -V`, uninstall.
9. **Docs.** CHANGELOG M6; SPEC §3, §13, §17, §18 R-M6-*; RELEASING.md; README-windows.txt in the zip.
10. **Gaps accepted by the owner:** R-M6-9 and the CI skips of 10.n.

Owner sign-off: name, date, RC tag, PASS/FAIL per line, decision (publish / fix and re-tag `N+1`).

## Self-review

- **Owner scope → tasks:**

  | Owner requirement | Tasks |
  |---|---|
  | x64 + ARM64 portable zip | 4, 8 (matrix), 10 |
  | Inno Setup installer, x64 + ARM64 | 5, 8 |
  | Version resource (FILEVERSION/PRODUCTVERSION, ProductName, icon) in both exes | 1, 2 |
  | `-Dversion-string=<zon>-win.<N>`, tag `win-<zon>-<N>`, pre-release; `Config.zig` and `win-` tags | 1 (R-M6-1), 9 (R-M6-7) |
  | Update check sees the releases | R-M5-9 unchanged; drafts invisible until published (R-M6-7); exit checklist 8 |
  | Workflow: build both, headless unit tests, package, draft pre-release on `win-*` | 8, 9, 10 |
  | `GITHUB_TOKEN` only; signing hook, owner signs manually (gap) | R-M6-6, R-M6-8, 4, 5, 9 |
  | Per-user, no admin; Start shortcut with AUMID | 5 (R-M6-4) |
  | Opt-in Explorer integration, uninstall reverts with `--all` | 3, 5 |
  | terminfo files; `tmux.exe` next to `ghostty.exe` | 4 (required files), 5 |
  | Uninstaller removes only its own; never the config | 3, 5, 7, 8; exit checklist 8 |
  | v1.0 acceptance checklist (E2E all green x64, ARM64 smoke by owner) | 12, § M6 exit checklist |
  | Owner-machine safety (HKCU, network, GUI only via e2e.ps1) | § Owner safety, 7 (`/DGhosttyTest`), 8 (CI-only guard) |
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
  | W3 | 8 | `windows-build.yml`, `windows-ci.yml`, `ci/install-zig.ps1`, `ci/installer-smoke.ps1` |
  | W4 | 9 | `windows-release.yml`, `ci/release-version.ps1`, `release-notes.md`, `docs/windows/RELEASING.md` |
  | W5 | 11 | CHANGELOG, SPEC, feature checklist, test README |

  No file is shared inside a wave. Cross-wave chains: `package.ps1` 4 → 10.n; `ghostty.iss` 5 → 10.n; the workflows 8/9 → 10.n. `src/build/Config.zig` follows the M5 19.n `tic` fix.
- **Names defined once:**

  | Task | Names |
  |---|---|
  | 1 | `windows_version.{TagKind,tagKind,winN,Error,fileVersion,rcHeader,Exe}` (`release.currentN` delegates) |
  | 2 | `GHOSTTY_*` rc macros (consumed from Task 1's header), `versioninfo.rc` |
  | 3 | `windows_explorer.{PathEql,ownsKeyFor}`, `UninstallOptions.only-this-exe` |
  | 4 | the `package.ps1` parameters |
  | 5 | `AppId`s, `AppAumid`, the `GhosttyTest`/`Sign` defines |
  | 8 | `windows-build.yml` inputs and artifact names |
  | 9 | `release-version.ps1` outputs, the notes placeholders |
- **Review Focus → tests:** 1 → Tasks 3, 7, 8; 2 → owner checklist; 3 → Tasks 1, 4, 9, 10; 4 → Tasks 8, 9 (opus), 10; 5 → Task 6; 6 → Task 10, owner checklist.
- **Proportion:** the code blocks are signatures, interfaces and command lines only.
- **Known risks:**
  - The ISCC compile is only checked where ISCC exists (CI always; locally per open question 2).
  - The workflows can be verified only by running them (Task 10, the owner's go).
  - `windows-11-arm` availability depends on the fork being public.

### Open questions → recommended answers (owner)

1. *Third-party notices:* the zip ships upstream's `LICENSE` only. Do fonts and libraries compiled in (JetBrains Mono under OFL, FreeType, HarfBuzz, …) need a `THIRD-PARTY-NOTICES.txt`? → Recommended: yes, before publishing v1.0 — one generated file listing the vendored packages of `build.zig.zon` with their licence names. It is a small 10.n task if accepted.
2. *Inno Setup on the dev machine:* install it per-user (`winget install JRSoftware.InnoSetup --scope user`) so that Task 5's compile check and `installer-test.ps1` run locally? → Recommended: yes. Without it, the installer is only checked on CI and in the owner's manual run.
3. *All-users install:* stays a gap for v1.0 (R-M6-4)? → Recommended: yes. It would need HKLM verbs and the common Start menu, and nobody has asked for it.
4. *ARM64 gating:* the ARM64 unit tests and installer smoke stay non-gating (R-M6-6)? → Recommended: yes for v1.0; make them gating after two green releases.
