# M4 final whole-branch review (tmux shim)

Reviewer: `final-m4`, 2026-10-28. Scope: every M4 commit on `windows`, from `35cf17b88` (ConPTY DCS probe) and `97a6133f6`
(Task 3) to `019c5031b` (acceptance). M4 started before the M3 close, so the range `6ccd6d811..HEAD` holds only the last
13 commits. Most of M4 (Tasks 3–13) landed before `6ccd6d811`, and this review covers all of it. Excluded: M5 (`9f0d79d8e`,
`828171e44`, `a5c9a0ffa`, `81fa2bfda` and everything after `019c5031b`) and M3 hotfixes that do not touch tmux. The code was
read at `019c5031b`, in a detached worktree `.claude/worktrees/final-m4`, because the main checkout already holds M5 commits
and another agent's uncommitted `drop.zig` edit.

Read first: the plan (Global Constraints, the exit checklist), the pre-flight review, the ledger
`.superpowers/sdd/M4-tmux-shim/progress.md`, and the acceptance in `CHANGELOG.md` "M4" and SPEC §17. There is no
`docs/windows/m4/acceptance.md`; see I3. Parked items are not re-raised:

- the DCS gap;
- the `wait-after-command` reload gap;
- the `__idle` pane left after a client timeout;
- `display-message` p95 32.2 ms;
- `MSYS_NO_PATHCONV` not set;
- the shared Claude login.

## Unit tests (this review, worktree at `019c5031b`, `-j6`, through the test-lock)

| Command | Result |
| --- | --- |
| `zig build test-tmux-shim` | PASS (main checkout, cached; the shim sources are identical at `019c5031b`) |
| `zig build test -Dtest-filter="win32 tmux "` | PASS 159/160 (1 skip); the first attempt failed on a build resource error (`failed to spawn: SystemResources`), the retry passed |
| `zig build test -Dtest-filter="tmux shim "` | PASS 106/107 (1 skip) |
| `zig build test -Dtest-filter="SplitTree"` | PASS 104/105 (1 skip) |

## What was checked and holds

- **Pipe security end to end.**
  - Client side:
    - `run.zig` accepts only `\\.\pipe\ghostty-tmux-<pid>-<16 hex>` (`protocol.tmuxPipePid`).
    - `pipe.zig` opens it with `SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION`.
    - It requires `GetFileType == PIPE` and `GetNamedPipeServerProcessId == pid` before it writes a byte.
  - Server side:
    - The pipe is claimed through `ipc.Server.claim`, with first instance, reject remote and the user-SID DACL (plus the HI
      label when elevated).
    - `peerMatchesAs` checks each client.
    - The frame cap is 4 MiB, the stdin cap of 512 KiB is checked again on the server, and `op` must be `tmux`.
    - The M2 pipe has no `tmux` op.
    - The test op `state`, which exposes the pipe name, is served only with `GHOSTTY_WIN32_TEST_IPC=1` at start.
  - The nonce comes from `randomSecure`. A silent client releases the queue after 500 + 200 ms.
- **Routing.** `routeIpc` routes on wparam before the main-server guard. A standalone process claims after
  `forwarded` and before `Window.create`. `terminate` stops the tmux server after the loop and after `appStopping`, with no
  dispatch in between.
- **Lifetimes.**
  - A tmux command runs inside one `WM_GHOSTTY_IPC`, and the single IPC thread blocks on `done`, so tmux requests never nest.
  - Every `Host` method re-resolves its pane or tab by id. `kill-pane -a` collects the ids first.
  - The caller's own kill is deferred until after the reply (`Surface.close` posts).
  - `Tab.removeSurface` of a tab's last pane goes through `removeTab`, and then `requestClose`, which posts. A window is
    therefore never freed under a running command.
  - A kill behind a close or paste dialog uses the M3 re-resolve, the `fromUserData` check and the `abandoned` flag. It is
    covered by the `tmux-replay` dialog step.
  - Respawn: `SplitTree.replace` refs the new surface, and `replaceTree` releases the old one synchronously.
    `Registry.surfaceDestroying` keeps the options because another live surface has the id.
  - Labels are keyed by `*Surface` and destroyed in `surfaceDestroying`. `Options` is reset (`self.* = .{}`) by `deinit`, so
    a `surfaceDestroying` after `appStopping` is safe.
- **Ids.**
  - Timer `msg_window.tmux_keys = 4` is unique. Ids 1–3 are M2/M3. The M5 skeleton, `sdd/task-m5-1`, takes 5–7 and
    `WM_APP + 16`.
  - `recovery.timer` returns null for a foreign id, so the chain reaches `pane_io.onTimer`.
  - No new window message. wparam `1` of `WM_GHOSTTY_IPC` is used only by the tmux `Server`.
- **Cost when tmux is never used.**
  - No timer is armed.
  - Labels do nothing while `options == null` (attached on the first request).
  - The Registry allocates nothing.
  - The pipe and its IPC thread exist by design (R-M4-1). Measured: +0.0 MB, 72.0 against 72.1.
  - One exception: `pane_io` (M1).
- **Upstream-shared hunks are minimal and gated.**
  - `SplitTree.replace` plus 3 tests.
  - The `windows-tmux-shim` key with its doc.
  - `findGitBash` and `isDeviceName` made `pub`.
  - `build.zig` creates the shim on every target, but installs it and adds its tests only for Windows/win32.
  - `stream.zig` gets tests only.
  - `GhosttyResources`/`Config.tic` are M5 (`81fa2bfda`).
- **Owner safety in the scripts.**
  - `_tmux.ps1` always uses the full path and `-S` for the scenario's own pipe, and removes `TMUX*`/`GHOSTTY_TMUX_*`.
  - `ClaudeRun.psm1` deletes only new files under `projects\*<unique work-dir leaf>*`, plus the work dir it created.
    `claude-team.ps1` deletes only `tasks\session-*` of the run's own team.
  - Both parse (PowerShell parser, 0 errors).

## Findings

### Critical

None.

### Important

**I1. Server-side output and input amplification is unbounded on the UI thread.**

Where:
- `src/apprt/win32/tmux/commands.zig:422-435` (`emitLine`);
- `commands.zig:288` (`Fmt.lookup` falls back to the stored options);
- `src/apprt/win32/tmux/pane_io.zig:56-72`;
- `src/apprt/win32/tmux/keys.zig:150`.

The caps cover the request (4 MiB) and each option value (8192 B), but not what a request expands to.

- **Output.** Take `set-option -g x <8192 bytes>`, then `display-message -p '#{x}#{x}…'`. A 4 MiB format asks the UI thread
  for ≈ 1 M × 8 KiB ≈ 8 GiB in its arena before `encodeResponse`. Any reply over the 16 MiB frame is refused by the client
  anyway. On the owner's low-RAM machine this freezes or pages out the Ghostty that holds all their panes. `list-panes -a -F`
  multiplies the same expansion by the pane count.
- **Input.** `send-keys -N` is capped at 16 MiB per call (`keys.zig:150`). After that cap:
  - `pane_io.sendKeys` dupes the bytes;
  - `toTextAction` escapes them, up to 4×, about 64 MiB more;
  - the queue keeps every call until the gate opens, with no total cap.

The client is same-user only, so this is robustness, not privilege. The server comment says "a hostile client does not run
tmux.exe, so its caps are checked here", and the expansion breaks that promise.

Fix:
- Cap `Output.stdout` and `Output.stderr`. Use 1 MiB, or `protocol.max_frame / 2`. Check in `emitLine`, `capturePane` and
  `showOptions` before appending, and fail `ghostty: reply too large`, exit 1.
- Cap `keys.encode` at `protocol.max_stdin_tmux`.
- Cap the `pane_io` queue at a total, for example 1 MiB. Over the cap, `sendKeys` returns an error and the command answers
  `ghostty: request too large`.
- Add one unit test per cap in `commands.zig` against `FakeHost`.

**I2. Privacy: personal data in pushed history and in HEAD.**

Commit `946b48316` is on `origin/windows` (github.com/Denmurzik/ghostty). It added
`src/apprt/win32/tmux/testdata/claude-spawn.jsonl` unsanitised:
- the Windows user name (`C:\Users\user\…`);
- the names of the owner's private Claude plugins (`--plugin-dir …\mods\plugin-a`, `plugin-b`,
  `plugin-c`);
- a Claude session UUID.

`aeba59a2a` sanitised the file, but the history keeps the original.

HEAD still has:
- `user` in the Task 10 test, at `src/apprt/win32/tmux/spawn.zig:228,240`;
- the real `--parent-session-id 00000000-…` in `claude-spawn.jsonl:17,30`.

Fix:
- Replace the user name in `spawn.zig` with `user`.
- Mask the session UUID in the fixture as `00000000-0000-0000-0000-000000000000`. The replay ignores it.
- History: owner decision. A force-push rewrite is destructive and must not be done without them. The user name is also
  in older committed files (`test/windows/e2e.ps1:121`), so the new exposure is the plugin names and the session id.

**I3. The acceptance close-out does not match the exit checklist.**

SPEC §17 marks M4 "done, accepted with concerns", but:
- exit checklist 2 (`E2E -Milestone all` has no new failures) is not recorded anywhere. The ledger defers it to this final
  batch.
- exit checklist 8 (the owner's manual checks, including `load-buffer -w` with a text clipboard) is pending. Only the
  feature checklist row says "owner manual check pending".
- Unlike M3 (`docs/windows/m3/acceptance.md`), there is no M4 acceptance document. The record is spread over the CHANGELOG
  and SPEC §17.

Fix:
- Run `E2E -Milestone all` (Debug) in the close batch and record the result.
- Add `docs/windows/m4/acceptance.md`: the exit checklist 1–9 with PASS / pending per line, pointing to the CHANGELOG
  table. Alternatively, state in SPEC §17 that the CHANGELOG is the record.
- List exit checklist 8 as an explicit pending owner item in SPEC §17.

### Minor

**M1. Cost with tmux unused: `pane_io` tracks every pane anyway.**

`pane_io.zig:125-138`: `layoutChanged` allocates `tab_changed_ms` and `pane_seen_ms` and records every pane at every layout
change, in every session, even if `tmux.exe` is never called. The data is bounded and small, but it breaks the "nothing
allocated when tmux is unused" rule.

Fix: return at the top of `layoutChanged` until the first tmux request. A flag `App.tmux.used`, set in `Registry.run`, would
do. `sendKeys` already dates an unseen pane "now", so a pane created before the first request just waits 300 ms once.

**M2. `pane_io.surfaceDestroying` drops by pane id, not by surface.**

`pane_io.zig:140-153`. Respawn shares a pane id between two surfaces. If `Tab.replaceSurface` fails after `Surface.create`
(`Tab.zig:505`, `surface.destroy()` when `tree.replace` fails), destroying the new surface drops the old, still-live pane's
queued keys and its `pane_seen_ms`. `Registry.surfaceDestroying` already guards this case with `other_alive`; `pane_io` does
not.

Fix: drop the queue items whose `item.surface == surface`. Remove `pane_seen_ms` only when no other live surface has the id,
reusing the scan of `Registry.surfaceDestroying`.

**M3. A dead, looser pid helper and an optional pid check.**

- `protocol.pidFromTmuxPipe` (`ipc/protocol.zig:82-95`) is used only by tests. It accepts names without `\\.\pipe\` and
  without a nonce.
- The doc of `pipe.request` (`src/tmux_shim/pipe.zig:31`) says the expected pid comes from it. The code uses
  `tmuxPipePid`.
- `expected_pid: ?u32` (`pipe.zig:36,55`) leaves a path that skips the server pid check. Production never takes it.

Fix: delete `pidFromTmuxPipe` and its asserts, make `expected_pid` a `u32`, and have the pipe tests pass
`GetCurrentProcessId()`.

**M4. `load-buffer -w` ignores `clipboard-write`.**

`commands.zig:709` calls `Registry.Host.setClipboard` (`Registry.zig:434`), which writes the Windows clipboard
unconditionally. In real tmux, `-w` sends OSC 52 to the outer terminal, and Ghostty gates that with `clipboard-write`. A user
with `clipboard-write = deny` still gets the clipboard set by any pane through the shim.

Fix: when `app.config.@"clipboard-write"` is `deny`, store the buffer and skip the clipboard. Log it at debug, or fail with
`load-buffer: clipboard writes are disabled`. Treat `ask` as allow, or route it through the M3 confirm.

**M5. SPEC wording is out of step with the code and rulings.**

- `SPEC.md:394` (§8.5) still lists "DCS `tmux;` passthrough unwrap in `src/terminal/dcs.zig`". R-M4-10 says there is no
  unwrap code.
- `SPEC.md:495` (§12.2) says the `cat` placeholder "blocks reading console input". It waits on its own process handle and
  reads nothing; §12.1 says so correctly.
- `SPEC.md:501` (§12.3) says "cwd = client cwd". The rule is `-c`, else the `cd` target, else the client cwd (R-M4-5).
- `SPEC.md:443` gives "-V p95 21 ms", but §17 calls 21 ms the `-V` p50 floor.
- The owner ruling "`MSYS_NO_PATHCONV` is not set" (native targets see MSYS path conversion) is recorded only in the ledger
  and the `spawn.zig:44-48` comment, not in SPEC §18 item 35 (R-M4-5).

Fix: one docs edit for the five points.

## Verdict

**READY_WITH_FIXES.**

No Critical findings. The security chain, the lifetimes, the ids and the upstream hunks hold end to end.

Before the close:
- fix I1 (caps plus 3 tests);
- fix the HEAD part of I2, and put the history question to the owner;
- complete I3 (`E2E -Milestone all` recorded, owner checks listed as pending).

M1–M5 may go into the same fix round or be parked.
