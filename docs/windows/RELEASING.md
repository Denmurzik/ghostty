# Releasing Ghostty for Windows

The owner's runbook. A release is built on the owner's machine by `dist/windows/release.ps1`. The script never tags, pushes or publishes: it prints those commands into `publish.txt` and you run them.

## 1. One-time setup

1. `gh auth login`.
2. `gh repo view Denmurzik/ghostty --json visibility` must print `PUBLIC`. The in-app update check and the downloads need a public repository.
3. In the fork's GitHub Settings, Actions, turn the upstream workflows off. They ask for runners the fork does not have, and some also run on tag pushes.
4. Download the NuGet package `Microsoft.Windows.Console.ConPTY` **1.25.260930003** (the `.nupkg` file). Pass it as `-ConptyPackage`. If you omit the parameter, the script uses the vendored copy under `vendor/conpty`, which holds the same version (hashes pinned in `vendor/conpty/README.md`). The script checks the version, the hashes and the Microsoft signature of all four files either way.
5. Inno Setup 6.4+ is already installed per user. The Visual Studio ARM64 component (`Microsoft.VisualStudio.Component.VC.Tools.ARM64`, admin install) is needed only for `-Arm64Abi msvc`. The default `-Arm64Abi gnu` needs nothing.

## 2. Push first

```
git push origin windows          # --force-with-lease after a rebase
git fetch --tags origin
```

Then:

- pick the next `N`: one above the highest `win-*-<N>` tag (`git tag -l "win-*"`); `N` starts at 1 and is never reused;
- add the CHANGELOG entry (`docs/windows/CHANGELOG.md`) and commit and push it too. The tree must be clean and HEAD must be on `origin/windows`, or the script refuses.

## 3. Build

```
PS> dist/windows/release.ps1 -N <N> -ConptyPackage <path to .nupkg> [-V1] [-Arm64TestExe]
```

- It takes about 1 to 2 hours. Run no other builds meanwhile: the script waits when free memory is below its gate (`-MinFreeGB`, default 6) and stops after 15 minutes.
- `-DryRun` runs the preflight only and prints every later command line. Try it first.
- `-Rehearsal -N 0` builds into `zig-out\release\rehearsal-<zon>\` and marks the printed commands `REHEARSAL - do not run`.
- `-SignCommand '<command with {file}>'` signs `ghostty.exe`, `tmux.exe`, `setup.exe` and the uninstaller (never the Microsoft ConPTY files).
- `-Arm64TestExe` also builds an ARM64 test exe and zips it as `ghostty-<v>-windows-arm64-tests.zip`. It is local only: not in `SHA256SUMS.txt` and not in `publish.txt`. Run it on an ARM64 device (exit 0 = PASS; a failure is recorded, not blocking). Put its result into the notes with `-Arm64Result '<text>'`, or edit `release-notes.md` before you run `publish.txt`.

Output, under `zig-out\release\<version>\`: six artifacts, `SHA256SUMS.txt`, `release-notes.md`, `publish.txt`, `tests.txt`, `release.log`. The `package.log` and `release.log` files are for you; never upload them.

## 4. Smoke the local artifacts

Do the owner part of the M6 exit checklist (`docs/windows/plans/M6-release.md`) on the files in that folder, including:

- the zip run from a downloaded location (Mark of the Web) and the setup run;
- Smart App Control: with it on, the unsigned build is blocked (not supported);
- SmartScreen: More info, Run anyway.

## 5. Optional signing

There is no certificate. To sign after the fact, repackage with `package.ps1 -FromZip` and `-SignCommand`, regenerate `SHA256SUMS.txt`, and `gh release upload --clobber`.

## 6. Publish

Open `publish.txt` and run its lines in PowerShell from the repo root, one by one:

1. `git tag -a ...` and `git push origin ...`
2. `gh release create ... --prerelease --draft ...`
3. Check the draft page on GitHub (files, notes, checksums).
4. `gh release edit ... --draft=false`

The update check ignores drafts, so users see the release only after the last command.

## 7. Check the update toast

Start an older installed build and confirm that the update toast offers the new release.

## 8. A bad release

Delete the GitHub release only (`gh release delete <tag>`). **Keep the tag**: its `N` is burned. Fix the problem and release `N+1`.
